import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / 'Sources/DoongdoongTranscription/Resources/align_transcript.py'
spec = importlib.util.spec_from_file_location('alignment', path)
alignment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alignment)


class AlignmentTests(unittest.TestCase):
    def test_no_text_is_lost_when_splitting_long_or_unspaced_transcript(self):
        for text in ['첫 문장. 다음 문장!', '말' * 201, '반복 반복\n반복\t반복', '수출은 100억, 수입은 20억입니다.']:
            result = alignment.sentences(text, limit=20)
            self.assertTrue(all(len(v) <= 20 for v in result))
            self.assertEqual(''.join(''.join(result).split()), ''.join(text.split()))

    def test_bad_matches_are_not_evenly_redistributed(self):
        for ranges in [[(1, 2, -10)], [(1, 1, -1)], [(1, 12, -1)], [(float('nan'), 2, -1)]]:
            with self.assertRaises(ValueError):
                alignment.validate(['원문'], ranges, 10)

    def test_gaps_and_repetitions_remain_at_measured_positions(self):
        result = alignment.validate(['반복', '반복'], [(1, 2, -1), (8, 9, -1)], 10)
        self.assertEqual([s['start'] for s in result], [1, 8])
        self.assertEqual([s['end'] for s in result], [2, 9])
        self.assertEqual([s['text'] for s in result], ['반복', '반복'])

    def test_numbers_are_only_normalized_for_matching(self):
        import re
        self.assertEqual(re.sub(r'\d+', alignment.korean_number, '1970년'), '천구백칠십년')
        self.assertEqual(re.sub(r'\d+', alignment.korean_number, '0'), '영')
        self.assertEqual(re.sub(r'\d+', alignment.korean_number, '12000'), '일만이천')

    def test_low_confidence_is_explicit_without_lowering_trusted_threshold(self):
        result = alignment.validate(['확실한 문장', '위치가 불확실한 문장'], [(1, 2, -1), (3, 6, -3)], 10, allow_uncertain=True)
        self.assertEqual([s['timingQuality'] for s in result], ['aligned', 'approximate'])
        self.assertEqual(result[1]['text'], '위치가 불확실한 문장')
        with self.assertRaises(ValueError):
            alignment.validate(['문장'], [(3, 6, -3)], 10)

    def test_short_lecture_tail_is_flagged_even_in_a_long_recording(self):
        import numpy as np
        emissions = np.full((1000, 3), -10.0)
        emissions[:, 0] = 0
        emissions[950:959, 1] = 1  # 180 ms confident nonblank evidence in a short trailing utterance.
        result = alignment.uncovered_ranges([{'start': 0, 'end': 18}], emissions, 20, offset=4000)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['start'], 4018)
        self.assertEqual(result[0]['end'], 4020)
        emissions[:, 1] = -10
        self.assertEqual(alignment.uncovered_ranges([{'start': 0, 'end': 18}], emissions, 20), [])

    def test_host_chunk_coordinates_and_joined_text_must_match_exactly(self):
        import copy
        bounds = [{'index': 0, 'startFrame': 0, 'endFrame': 16000}]
        data = {'text': '원문', 'manifest': {'sampleRate': 16000, 'totalFrames': 16000, 'chunks': bounds},
                'chunks': [{'chunk': bounds[0], 'response': {'text': '원문'}}]}
        self.assertEqual(alignment.transcript_parts(data, 16000), [(0, 16000, '원문')])
        for key, value in [('text', '다른 문장')]:
            invalid = copy.deepcopy(data); invalid[key] = value
            with self.assertRaises(ValueError):
                alignment.transcript_parts(invalid, 16000)
        invalid = copy.deepcopy(data); invalid['chunks'][0]['chunk']['startFrame'] = 1
        with self.assertRaises(ValueError):
            alignment.transcript_parts(invalid, 16000)


if __name__ == '__main__':
    unittest.main()
