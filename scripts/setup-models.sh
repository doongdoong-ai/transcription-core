#!/bin/bash
# Acoustic alignment only. Speech recognition uses ChatGPT file dictation.
set -euo pipefail
runtime_dir="${1:-$HOME/Library/Application Support/Doongdoong/Alignment}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
python="${DOONGDOONG_PYTHON:-$(command -v python3.13 || true)}"
[[ -n "$python" ]] || { echo '먼저 brew install python@3.13 ffmpeg를 실행하세요.' >&2; exit 1; }
mkdir -p "$runtime_dir/models/hub/checkpoints"
lock_dir="$runtime_dir/.alignment-setup.lock"
mkdir "$lock_dir" 2>/dev/null || { echo '정렬 도구 설치가 이미 진행 중입니다.' >&2; exit 1; }
partial=""
cleanup() { [[ -z "$partial" ]] || rm -f -- "$partial"; rmdir "$lock_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -x "$runtime_dir/venv/bin/python" ]] || "$python" -m venv "$runtime_dir/venv"
"$runtime_dir/venv/bin/python" -m pip install --disable-pip-version-check -r "$script_dir/alignment-requirements.txt"
model="$runtime_dir/models/hub/checkpoints/model.pt"
expected="20ef12963ab4924bef49ac4fc7f58ad5da2ee43b2c11bc8c853c9b90ecdbc680"
if [[ ! -f "$model" ]] || [[ "$(shasum -a 256 "$model" | cut -d ' ' -f 1)" != "$expected" ]]; then
    echo 'MMS_FA 정렬 모델 다운로드 (약 1.18 GB, CC BY-NC 4.0). THIRD_PARTY.md 참조.'
    partial="$(mktemp "$runtime_dir/models/hub/checkpoints/.download.XXXXXX")"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 3600 --output "$partial" \
        https://dl.fbaipublicfiles.com/mms/torchaudio/ctc_alignment_mling_uroman/model.pt
    [[ "$(shasum -a 256 "$partial" | cut -d ' ' -f 1)" == "$expected" ]] || { echo '정렬 모델 검증 실패' >&2; exit 1; }
    mv -f "$partial" "$model"
    partial=""
fi
"$runtime_dir/venv/bin/python" -c 'import torch, torchaudio, uroman, ctc_segmentation; assert hasattr(torchaudio.pipelines, "MMS_FA")'
echo "재생 위치 정렬 준비 완료: $runtime_dir"
