# 외부 구성요소

패키지 코드는 MIT입니다. 음성 인식 모델을 포함하거나 배포하지 않습니다.

- Apple Speech / AVFoundation / CoreMedia: macOS 시스템 프레임워크. SDK·OS 사용 조건 적용.
- Apple 음성 인식 언어 모델: `AssetInventory`가 시스템 자산으로 관리하며 Apple의 조건 적용. 패키지의 MIT 대상이 아닙니다.
- Foundation / CryptoKit: 시스템 프레임워크. 파일 처리·체크포인트 무결성 검증에 사용합니다.

0.1.2의 whisper.cpp·Whisper 모델·Silero VAD 설치와 라이선스 기록은 해당 Git 태그의 `THIRD_PARTY.md`와 `scripts/setup-models.sh`에서 확인할 수 있습니다. 0.3.0의 실행 의존성이 아닙니다.
