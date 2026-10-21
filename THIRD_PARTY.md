# 외부 구성요소와 라이선스

전사 코어와 파일 전송·로그인 연결·시간 정렬을 연결하는 자체 코드는 MIT 라이선스다. 외부 프로젝트의 전사 클라이언트 코드는 복사하거나 포함하지 않았다. 공개 구현에서 파일 업로드 방식의 가능성을 확인하고 별도로 구현했다.

## 시간 정렬 모델

`MMS_FA`는 Meta의 *Scaling Speech Technology to 1,000+ Languages* 연구에서 공개한 다국어 음성 모델이다. **CC BY-NC 4.0**이 적용되며 앱의 MIT 라이선스로 재허가되지 않는다. 설치 스크립트가 별도로 다운로드하며 저장소나 앱 번들에 가중치를 포함하지 않는다. 상업적 사용까지 허용하는 MIT 모델이라고 해석하면 안 된다.

- 모델 출처: https://dl.fbaipublicfiles.com/mms/torchaudio/ctc_alignment_mling_uroman/model.pt
- 모델 라이선스: https://github.com/facebookresearch/fairseq/tree/100cd91db19bb27277a06a25eb4154c805b10189/examples/mms#license
- 설치 시 검증하는 SHA-256: `20ef12963ab4924bef49ac4fc7f58ad5da2ee43b2c11bc8c853c9b90ecdbc680`

음성의 프레임별 문자 확률을 계산하는 데 사용하며, 전사문을 생성하거나 교정하지 않는다. 전사문은 OpenAI 파일 받아쓰기 결과 그대로 유지한다.

## 정렬 실행 환경

- PyTorch·TorchAudio: BSD 계열, 설치 패키지의 LICENSE 참조.
- uroman: 설치 패키지의 LICENSE는 MIT 형식에 출판 시 사용 사실을 명시하는 조건을 추가한다(패키지 분류자의 Apache 표기와 다르므로 실제 LICENSE를 따른다). 정렬용 로마자 표기만 만들며 화면의 원문을 대체하지 않는다.
- ctc-segmentation: Apache 2.0. 음향 확률과 주어진 전사문으로 시간 정렬을 계산한다.
- NumPy: BSD 3-Clause.
- FFmpeg: 사용자 설치 빌드의 라이선스가 적용된다. 앱에 재배포하지 않는다.

Python 패키지는 독립된 가상 환경에 설치한다. 버전은 `scripts/alignment-requirements.txt`에 고정한다. TorchAudio 2.9에서 제거된 API에 의존하므로 2.8.0으로 고정했으며, 업데이트 시 모델 로딩·출력 시간축·정렬 검증을 함께 확인해야 한다.

This project uses the universal romanizer software 'uroman' written by Ulf Hermjakob, USC Information Sciences Institute (2015-2020).

Ulf Hermjakob, Jonathan May, and Kevin Knight. 2018. *Out-of-the-box universal romanization tool uroman*. Proceedings of the 56th Annual Meeting of the Association for Computational Linguistics, Demo Track.

## Codex 파일 받아쓰기

기존 Codex의 ChatGPT 로그인 인증으로 OpenAI의 내부 파일 받아쓰기 엔드포인트를 이용한다. 공개·안정 API라는 보장은 없으며, 특정 음성 인식 모델·사용량·가격을 클라이언트가 지정하지 않는다. 외부 ASR 래퍼는 의존성에 포함하지 않는다.
