# 외부 구성요소

이 저장소의 Swift 세션·프로세스 관리 코드는 MIT입니다. PCM 읽기·쉼 탐지·복구의 일부는 같은 조직의 둥둥이 MIT 코드에서 분리·수정했으며 저작권 표기를 유지합니다. 외부 ASR 래퍼 코드를 가져오지 않았습니다.

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp): MIT. 별도로 설치한 `whisper-server` 실행 파일을 사용합니다.
- [OpenAI Whisper](https://github.com/openai/whisper): 코드와 모델 가중치는 MIT. 기본 `large-v3-turbo` GGML 변환본은 `ggerganov/whisper.cpp`에서 별도 다운로드합니다.
- [Silero VAD](https://github.com/snakers4/silero-vad): MIT. GGML 변환본은 `ggml-org/whisper-vad`에서 별도 다운로드합니다.

설치 스크립트에 모델별 SHA-256과 다운로드 원본을 기록합니다. 엔진 바이너리·모델 가중치·사용자 음성·인증 정보는 이 저장소에 포함하지 않습니다.
