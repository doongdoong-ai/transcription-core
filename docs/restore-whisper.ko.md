# 이전 Whisper 엔진 복구 기준

현재 전사 엔진은 Apple Speech입니다. 이전 구현은 삭제된 코드를 복사해 함께 빌드하지 않고 Git 이력으로 보존합니다.

- 패키지: `doongdoong-ai/transcription-core`, 태그 `0.1.2`, 커밋 `db8d998094b9ae56ba66bb89c3d286418900b1bb`.
- 앱: `doongdoong-ai/doongdoong`, 커밋 `ee286472a3885a8639bf9ffe4c679b92b3dd2a57`.
- 당시 구성: whisper.cpp 1.9.5, large-v3-turbo FP16, Silero v6.2.0, 60초 증분 세션.

복구는 별도 브랜치에서 패키지와 앱 어댑터를 함께 되돌립니다. 해당 태그의 모델 설치 스크립트·라이선스 고지를 읽고 필요한 모델만 다시 설치합니다. `WhisperConfiguration`/`WhisperEngine`과 앱의 타임스탬프 표시·설정·설치 문서도 함께 복구해야 합니다. Apple 체크포인트를 이전 엔진 결과로 읽지 마세요. 기존 녹음·교정문·사용자 편집은 덮어쓰지 않습니다.

현재 선택은 M1·한국어 표본에서 확인한 처리 속도 이득에 따른 제품 결정이며, Apple이 더 정확하다고 입증한 결과가 아닙니다. 정확도 비교 자료는 앱 이슈 #12와 비공개 `.local/apple-whisper-benchmark-2026-10-22/`에 보존되어 있습니다.
