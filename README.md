# Doongdoong Transcription

**녹음 중인 WAV를 5분씩 파일로 전사하고, 문장별 재생 위치와 재개 기록을 반환하는 Swift 패키지입니다.** 둥둥이의 녹음 UI·텍스트 교정·제목·요약과 독립적으로 사용할 수 있습니다.

```text
16 kHz mono PCM16 WAV
    → 완료된 구간을 최대 5분씩 AAC 파일로 변환
    → ChatGPT 받아쓰기 서버에서 원문 수신
    → Mac의 MMS_FA + CTC 정렬로 문장 시간 계산
    → 구간 체크포인트 저장 → 다음 구간
```

Codex CLI는 ChatGPT 로그인만 제공합니다. 음성 인식을 위해 모델 턴이나 에이전트 도구를 호출하지 않습니다. 내부 `https://chatgpt.com/backend-api/transcribe`에 직접 파일을 전송하며, 음성 인식 모델은 클라이언트에서 지정하지 않습니다. 공개 음성 API와는 다른 경로로, 계정별 한도·과금·장기 지원은 확인되지 않았습니다. API 키 결제로 자동 전환하지 않습니다.

## 설치

macOS 14+, Swift 6, Codex CLI의 ChatGPT 로그인이 필요합니다. Apple M1·8 GB에서 확인했으며 Linux·Docker를 지원한다고 가정하지 마세요.

```sh
brew install python@3.13 ffmpeg
./scripts/setup-models.sh
swift build -c release
```

Python 가상환경과 정렬 모델의 기본 위치는 `~/Library/Application Support/Doongdoong/Alignment`입니다. 모델은 SHA-256을 확인해 재사용합니다. **MMS_FA 가중치는 CC BY-NC 4.0**이며 이 저장소 코드의 MIT 라이선스와 다릅니다. 정렬 모델은 텍스트를 생성하지 않고 주어진 문장과 음성을 맞춥니다. 자세한 출처·라이선스는 [THIRD_PARTY.md](THIRD_PARTY.md)에 있습니다.

## Swift에서 사용하기

```swift
import DoongdoongTranscription

let home = FileManager.default.homeDirectoryForCurrentUser
let alignment = home.appendingPathComponent("Library/Application Support/Doongdoong/Alignment")
let configuration = TranscriptionConfiguration(
    codex: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
    ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
    python: alignment.appendingPathComponent("venv/bin/python"),
    alignmentModelDirectory: alignment.appendingPathComponent("models"),
    language: "ko"
)
let session = TranscriptionSession(audio: audioURL, directory: jobDirectory,
    configuration: configuration, recognizer: ChatGPTSpeechRecognizer.shared)
try TranscriptionSession.prepareRecording(directory: jobDirectory) // 녹음기 시작 전에
try await session.processAvailable(final: false) // 녹음 중 주기적으로 호출
let segments = try await session.processAvailable(final: true) { progress in
    print(progress.phase, progress.processedSeconds, progress.totalSeconds)
} // WAV를 닫은 뒤 마지막 잔여 구간 처리
```

진행률은 받아쓰기와 정렬을 모두 마쳐 커밋된 음성 길이입니다. `phase`는 현재 구간의 인식·정렬을 구분합니다. 약 5분 경계의 마지막 5초에서 쉼을 찾으며 구간을 중복 전송하지 않습니다. 완전한 디지털 무음은 서버에 보내지 않습니다. 각 세그먼트의 `timingQuality`는 `aligned` 또는 `approximate`이며 불확실한 위치를 정확한 따라읽기로 표시하면 안 됩니다.

앱 번들을 직접 패키징할 때는 SwiftPM의 `DoongdoongTranscription_DoongdoongTranscription.bundle`을 앱의 `Contents/Resources`에 포함하세요.

## 실패와 재개

구간별 원문은 정렬보다 먼저 원자적으로 저장합니다. 정렬이 실패하거나 취소되면 같은 PCM·언어의 응답을 재사용하며, 정렬 완료 후에만 전체 세션 커서를 옮깁니다. 원문·정렬·완료 체크포인트는 `transcription/`에 저장합니다. 실행 도구·정렬 모델·설정의 식별 정보와 PCM 해시를 검증하며, 같은 녹음의 중복 처리는 파일 잠금으로 막습니다.

401은 토큰을 갱신해 한 번 재시도합니다. 그 외 네트워크·인증·빈 응답·429·정렬 실패는 호출자에게 반환합니다. UI와 재시도 정책은 호출 앱이 소유합니다. 공유 recognizer는 구간 처리를 직렬화해 정렬 모델이 동시에 여러 개 로드되지 않게 합니다. 취소 시 HTTP와 자식 프로세스를 중단합니다. 응답이 저장되기 전에 종료하면 서버에서 이미 처리한 요청도 재전송될 수 있습니다.

`recoverInterrupted(audio:directory:)`는 녹음 전 표식이 있는 미완성 WAV를 별도 `audio-recovered.wav`로 복구합니다. 원본·기존 복구본을 덮어쓰지 않고, 디스크에 남은 완전한 PCM만 사용합니다. 이전 버전의 녹음 표식도 읽지만 이전 엔진의 전사 캐시는 새 결과로 재사용하지 않습니다.

## CLI와 검증

```sh
swift run doongdoong-transcribe recording.wav result \
  /opt/homebrew/bin/codex /opt/homebrew/bin/ffmpeg \
  "$HOME/Library/Application Support/Doongdoong/Alignment/venv/bin/python" \
  "$HOME/Library/Application Support/Doongdoong/Alignment/models" ko
swift test
"$HOME/Library/Application Support/Doongdoong/Alignment/venv/bin/python" \
  -m unittest discover -s Tests/Alignment
```

CLI는 실제 서버로 음성을 전송하며 `result/segments.json`을 저장합니다. 단위 테스트는 서버·모델 다운로드 없이 인증 RPC 제한, 정렬 검증, 정렬 실패 후 응답 재사용, 짧은 마지막 구간, 음성 변조 검출, 복구와 진행률을 검사합니다. Python 검사는 NumPy만 필요합니다.

이전 로컬 전사 구현은 태그 `0.1.2`에 보존되어 있습니다. 앱과 함께 복원하는 절차는 `doongdoong-ai/doongdoong` 저장소의 `docs/restore-whisper.ko.md`에 정리했습니다. 현재 0.2 계열은 설정·recognizer API가 달라 이전 버전과 소스 호환되지 않습니다.
