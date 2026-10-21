#!/usr/bin/env python3
"""Align a supplied transcript; never decode, rewrite, or generate transcript text.

The acoustic model and CTC segmentation are dependencies, not vendored code.
Our code controls bounded inference, exact text mapping and confidence checks.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import wave


def sentences(text, limit=90):
    """Readable spans with no loss of non-whitespace characters."""
    result = []
    # Dictation sometimes returns Korean without punctuation. Keep the original
    # words, but use common spoken endings as reading boundaries.
    endings = ["니다", "세요", "예요", "어요", "아요", "네요", "거죠", "그렇죠"]
    boundary = r"(?<=[.!?。！？])\s+|[\r\n]+|" + "|".join(r"(?<=" + ending + r")\s+" for ending in endings)
    for paragraph in re.split(boundary, text):
        current = ""
        for word in paragraph.split():
            if current and len(current) + len(word) + 1 > limit:
                result.append(current)
                current = ""
            # Bound even transcripts without spaces.
            while len(word) > limit:
                if current:
                    result.append(current)
                    current = ""
                result.append(word[:limit])
                word = word[limit:]
            current = (current + " " + word).strip()
        if current:
            result.append(current)
    if not result or "".join("".join(result).split()) != "".join(text.split()):
        raise ValueError("text_mapping")
    return result


def korean_number(match):
    digits = "영일이삼사오육칠팔구"
    value = match.group()
    if len(value) > 12 or value.startswith("0"):
        return "".join(digits[int(c)] for c in value)
    number = int(value)
    if number == 0:
        return "영"
    groups = []
    for unit in ["", "만", "억"]:
        group = number % 10000
        number //= 10000
        part = ""
        for place, name in [(1000, "천"), (100, "백"), (10, "십"), (1, "")]:
            count, group = divmod(group, place)
            if count:
                part += ("" if count == 1 and place > 1 else digits[count]) + name
        if part:
            groups.insert(0, part + unit)
    return "".join(groups)


def normalized_spans(spans, romanizer, language):
    output = []
    if language == "auto" and any(re.search("[가-힣]", span) for span in spans):
        language = "ko"
    iso = {"ko": "kor", "en": "eng", "ja": "jpn"}.get(language)
    for span in spans:
        spoken = re.sub(r"\d+", korean_number, span) if language == "ko" else span
        latin = romanizer.romanize_string(spoken, lcode=iso).lower()
        latin = re.sub("[^a-z' ]", " ", latin)
        latin = " ".join(latin.split())
        if not latin:
            raise ValueError("unalignable_text")
        output.append(latin)
    return output


def validate(spans, alignments, duration, minimum_score=-2.0, allow_uncertain=False):
    if len(spans) != len(alignments):
        raise ValueError("alignment_count")
    result = []
    previous_end = 0.0
    for index, (text, (start, end, score)) in enumerate(zip(spans, alignments)):
        start, end, score = float(start), float(end), float(score)
        if not all(math.isfinite(v) for v in (start, end, score)):
            raise ValueError("alignment_nonfinite")
        if score < minimum_score and not allow_uncertain:
            raise ValueError("alignment_low_confidence")
        # Round-off is tolerated; a contradictory alignment must not be silently repaired.
        if start < previous_end - 0.04 or start < -0.04 or end > duration + 0.04 or end <= start:
            raise ValueError("alignment_timeline")
        start, end = max(previous_end, start, 0.0), min(duration, end)
        if end <= start:
            raise ValueError("alignment_span")
        uncertain = score < minimum_score or end - start > max(30.0, len(text) * 1.2)
        if uncertain and not allow_uncertain:
            raise ValueError("alignment_span")
        result.append({"id": index, "start": start, "end": end, "text": text,
                       "originalText": text, "alignmentScore": score,
                       "timingQuality": "approximate" if uncertain else "aligned"})
        previous_end = end
    return result


def uncovered_ranges(segments, emissions, duration, offset=0.0):
    """Suspected gaps, not a guarantee of speech or a transcription accuracy score."""
    import numpy as np
    active = (emissions.argmax(axis=1) != 0) & (emissions.max(axis=1) > -2.5)
    gaps = []
    intervals = [(0.0, segments[0]["start"])] if segments else [(0.0, duration)]
    intervals += [(left["end"], right["start"]) for left, right in zip(segments, segments[1:])]
    if segments:
        intervals.append((segments[-1]["end"], duration))
    for start, end in intervals:
        # Exclude the known 40 ms playback margins and tiny between-word gaps.
        first, last = max(0, int((start + 0.08) / 0.02)), min(len(active), int((end - 0.08) / 0.02))
        frames = int(active[first:last].sum())
        if end - start >= 0.8 and frames >= 4:
            gaps.append({"start": start + offset, "end": end + offset,
                         "reason": "unmatched_audio", "speechFrames": frames})
    return gaps


def align_text(text, emissions, duration, language="ko"):
    from uroman import Uroman
    from ctc_segmentation import CtcSegmentationParameters, prepare_text, ctc_segmentation, determine_utterance_segments
    import torchaudio
    spans = sentences(text)
    targets = normalized_spans(spans, Uroman(), language)
    labels = list(torchaudio.pipelines.MMS_FA.get_labels(star=None))
    config = CtcSegmentationParameters(char_list=labels)
    config.index_duration = 0.02
    config.replace_spaces_with_blanks = True
    config.blank_transition_cost_zero = True
    ground, boundaries = prepare_text(config, targets)
    budget_window = (256 * 1024 * 1024) // (4 * len(ground))
    if budget_window < 64:
        raise ValueError("alignment_capacity")
    # A fixed 8,000-frame band (160 seconds) can fail or end early on a
    # five-minute chunk. Search its whole time range when the memory budget permits.
    config.min_window_size = min(len(emissions), budget_window)
    config.max_window_size = config.min_window_size + 1
    timings, probabilities, _ = ctc_segmentation(config, emissions, ground)
    scored = determine_utterance_segments(config, boundaries, probabilities, timings, targets)
    ranges = [(max(0.0, timings[boundaries[i] + 1] - 0.04),
               min(duration, timings[boundaries[i + 1] - 1] + 0.04), score)
              for i, (_, _, score) in enumerate(scored)]
    for i in range(1, len(ranges)):
        start, end, score = ranges[i]
        prior_end = ranges[i - 1][1]
        if 0 < prior_end - start <= 0.081:
            ranges[i] = (prior_end, end, score)
    return validate(spans, ranges, duration, allow_uncertain=True)


def infer_emissions(waveform, args):
    import numpy as np
    import torch
    import torchaudio
    count = len(waveform)
    frames = (count - 400) // 320 + 1
    bundle = torchaudio.pipelines.MMS_FA
    labels = list(bundle.get_labels(star=None))
    cache = None
    if getattr(args, "cache_directory", None):
        folder = Path(args.cache_directory)
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Hash PCM and inference geometry, independently of transcript revisions.
        digest = hashlib.sha256(waveform.tobytes()).hexdigest()
        cache = folder / ("mms-fa-800-50-v2-" + digest + ".npy")
        if cache.exists() and cache.stat().st_size <= frames * len(labels) * 4 + 4096:
            try:
                saved = np.load(cache, allow_pickle=False, mmap_mode="r")
                if saved.shape == (frames, len(labels)) and saved.dtype == np.float32 and np.isfinite(saved).all():
                    return saved
            except (ValueError, OSError):
                pass
    torch.set_num_threads(4)
    torch.hub.set_dir(str(Path(args.model_directory) / "hub"))
    if not (Path(torch.hub.get_dir()) / "checkpoints" / "model.pt").is_file():
        raise ValueError("model_missing")
    model = bundle.get_model(with_star=False).eval()
    device = "mps" if args.device == "mps" and torch.backends.mps.is_available() else "cpu"
    model = model.to(device)
    emissions = np.empty((frames, len(labels)), dtype=np.float32)
    with torch.inference_mode():
        for first in range(0, frames, 800):
            last = min(frames, first + 800)
            left, right = max(0, first - 50), min(frames, last + 50)
            sample = torch.from_numpy(waveform[left * 320:(right - 1) * 320 + 400]).unsqueeze(0).to(device)
            scores, _ = model(sample)
            values = scores[0, first - left:last - left].cpu().numpy()
            if values.shape != (last - first, len(labels)):
                raise ValueError("emission_geometry")
            emissions[first:last] = values
            print(json.dumps({"phase": "alignment", "frames": last, "total": frames}), flush=True)
    del model
    if cache:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=cache.parent, prefix=".emissions-", delete=False) as stream:
                temporary = stream.name
                np.save(stream, emissions, allow_pickle=False)
            os.replace(temporary, cache)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
    return emissions


def transcript_parts(payload, count):
    """Validate host-owned sample bounds. No model-produced timestamps are accepted."""
    if "chunks" not in payload:
        return [(0, count, payload["text"])]
    manifest = payload["manifest"]
    entries = payload["chunks"]
    if manifest["sampleRate"] != 16000 or manifest["totalFrames"] != count or not entries:
        raise ValueError("chunk_manifest")
    expected = 0
    parts = []
    for index, entry in enumerate(entries):
        bounds = entry["chunk"]
        start, end = bounds["startFrame"], bounds["endFrame"]
        if bounds != manifest["chunks"][index] or bounds["index"] != index or start != expected or end <= start or end > count:
            raise ValueError("chunk_coverage")
        text = entry["response"]["text"]
        if not isinstance(text, str) or (not text and not entry["response"].get("skippedDigitalSilence")):
            raise ValueError("chunk_text")
        parts.append((start, end, text))
        expected = end
    if expected != count or len(entries) != len(manifest["chunks"]) or "\n".join(p[2] for p in parts if p[2]) != payload["text"]:
        raise ValueError("chunk_coverage")
    return parts


def recovery_parts(payload, count):
    regions = payload.get("regions", [])
    if not regions or len(regions) > 64:
        raise ValueError("recovery_regions")
    parts, previous = [], 0
    for region in regions:
        start, end, text = region["startFrame"], region["endFrame"], region["text"]
        if not isinstance(start, int) or not isinstance(end, int) or start < previous or end <= start or end > count or end - start > 300 * 16000:
            raise ValueError("recovery_bounds")
        if not isinstance(text, str) or not text.strip():
            raise ValueError("recovery_text")
        parts.append((start, end, text)); previous = end
    if "\n".join(p[2] for p in parts) != payload["text"]:
        raise ValueError("recovery_text")
    return parts


def align(args):
    import numpy as np
    payload = json.loads(Path(args.transcript).read_text(encoding="utf-8"))
    text = payload["text"]
    if not isinstance(text, str) or len(text) > 500_000:
        raise ValueError("text_size")
    with wave.open(args.audio, "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError("audio_format")
        count = audio.getnframes()
        if count < 400 or count > 16000 * 4 * 3600:
            raise ValueError("audio_duration")
        waveform = np.frombuffer(audio.readframes(count), dtype="<i2").astype(np.float32) / 32768.0
    parts = recovery_parts(payload, count) if getattr(args, "regions", False) else transcript_parts(payload, count)
    duration = count / 16000
    emissions = infer_emissions(waveform, args)
    del waveform
    segments, gaps = [], []
    for start, end, source in parts:
        # Anchor every part to the original 20 ms emission lattice. At most one
        # partial frame is excluded at each boundary; offsets never accumulate.
        first = math.ceil(start / 320)
        last = min(len(emissions), (end - 400) // 320 + 1)
        offset = first * 0.02
        local_duration = end / 16000 - offset
        if not source:
            continue
        try:
            if last <= first:
                raise ValueError("short_speech_chunk")
            local = align_text(source, emissions[first:last], local_duration, args.language)
            gaps += uncovered_ranges(local, emissions[first:last], local_duration, offset)
        except (ValueError, IndexError, AssertionError):
            # A failed CTC path must not suppress the rest of the recording. Keep
            # this source as one explicitly approximate paragraph at its known
            # FILE bounds; never manufacture sentence timings within the region.
            offset = start / 16000
            local = [{"id": 0, "start": 0.0, "end": (end - start) / 16000,
                      "text": source, "originalText": source,
                      "alignmentScore": -100000.0, "timingQuality": "approximate"}]

        for segment in local:
            segment["id"] = len(segments)
            segment["start"] += offset
            segment["end"] += offset
            segments.append(segment)
    return {"schemaVersion": 2, "method": "mms-ctc-forced-alignment", "duration": duration,
            "segments": segments, "text": text, "reviewRanges": gaps,
            "uncertainSegments": sum(s["timingQuality"] != "aligned" for s in segments)}


def watch_parent():
    """Stop model work if the owning app dies without running its cancellation handler."""
    import threading
    import time
    owner = os.getppid()
    if owner <= 1:
        os._exit(70)
    def monitor():
        while True:
            time.sleep(0.25)
            if os.getppid() != owner:
                os._exit(70)
    threading.Thread(target=monitor, daemon=True).start()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model-directory", required=True)
    parser.add_argument("--language", choices=["ko", "en", "ja", "auto"], default="ko")
    parser.add_argument("--cache-directory")
    parser.add_argument("--regions", action="store_true")
    parser.add_argument("--device", choices=["cpu", "mps"], default="cpu")
    parser.add_argument("--watch-parent", action="store_true")
    args = parser.parse_args()
    if args.watch_parent:
        watch_parent()
    temporary = None
    try:
        result = align(args)
        destination = Path(args.output)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent,
                                         prefix=".alignment-", delete=False) as stream:
            temporary = stream.name
            json.dump(result, stream, ensure_ascii=False, allow_nan=False)
        os.replace(temporary, destination)
    except Exception as error:
        # No transcript, authentication or arbitrary exception content in logs.
        code = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z_]+", str(error)) else type(error).__name__
        print(json.dumps({"error": code}), file=sys.stderr)
        return 1
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
