# Doongdoong Transcription

**모델을 메모리에 유지하고, 녹음 중 새로 쌓인 음성을 순차 전사하는 Swift 패키지.**

둥둥이에서 전사만 분리한 코어입니다. 입력은 녹음 중이거나 완성된 WAV, 출력은 원문과 문장별 타임스탬프입니다. 교정·제목·요약, UI, 계정 로그인은 포함하지 않습니다. Codex·Claude·API 키·구독 없이 실행합니다.

## 처리 방식

```text
계속 저장되는 WAV
    → 약 60초의 미처리 구간 (끝부분의 쉼을 우선)
    → 메모리에 유지한 Whisper + 음성 감지
    → 원문 · 시작/종료 시간 · 처리 기록
녹음 종료 → 마지막 남은 구간 → 하나의 전사문
```

`WhisperEngine` 하나를 여러 세션이 공유합니다. 첫 요청에서 `whisper-server`를 실행하고 모델을 올린 뒤 다음 요청부터 재사용합니다. HTTP는 Mac 내부 `127.0.0.1`에서만 사용하며 클라우드에 음성을 보내지 않습니다. 작업은 FIFO로 직렬 처리하므로 모델 여러 개가 동시에 메모리를 차지하지 않습니다.

`TranscriptionSession`은 이미 처리한 PCM을 다시 인식하지 않습니다. 완료한 구간을 원자적으로 저장하고 재시도 시 PCM SHA-256과 설정을 검증합니다. 언어·모델 파일의 식별 정보·분할 설정이 바뀌면 별도 캐시를 사용합니다. 같은 녹음의 중복 실행은 파일 잠금으로 막습니다. 모델 파일은 실행 중 수정하지 마세요.

Silero VAD로 발화 구간을 감지하며 디지털 무음은 디코더에 전달하지 않습니다. 녹음의 끝이 짧아도 마지막 구간을 버리지 않습니다. 반환 시간은 Whisper의 세그먼트 타임스탬프이며 단어 단위 강제 정렬이나 정확도 보증은 아닙니다.

## 준비

macOS 14 이상, Swift 6, whisper.cpp 1.9.5에서 검증했습니다. 현재 패키지는 macOS용이며 Linux·Docker 지원은 아직 없습니다. 기본 모델은 `large-v3-turbo` FP16, VAD는 Silero 6.2.0입니다.

```sh
brew install whisper.cpp
./scripts/setup-models.sh
swift test
```

모델은 처음 한 번 별도로 받으며 저장소와 패키지에 포함하지 않습니다. 설치 스크립트는 SHA-256을 확인하고 기존 모델을 재사용합니다. 설치 후 전사에는 인터넷이 필요 없습니다.

## Swift에서 사용하기

Swift Package Manager 의존성에 `doongdoong-ai/transcription-core`의 `0.1.0`을 추가하고 `DoongdoongTranscription` 제품을 연결합니다.

```swift
import DoongdoongTranscription

let engine = WhisperEngine() // 앱에서 공유: 녹음마다 만들지 않습니다.
let configuration = WhisperConfiguration(
    executable: serverURL, model: modelURL, vadModel: vadURL,
    language: "ko", chunkSeconds: 60
)
let session = TranscriptionSession(
    audio: recordingURL, directory: workDirectory,
    configuration: configuration, recognizer: engine
)

// WAV를 계속 기록하는 동안 주기적으로, 이전 호출이 끝난 뒤 호출합니다.
let partial = try await session.processAvailable(final: false)
// 녹음기를 닫고 진행 중인 호출을 기다린 뒤:
let complete = try await session.processAvailable(final: true)
// 더 이상 사용할 때가 없거나 앱을 종료할 때:
await engine.unload()
```

입력은 **16 kHz·모노·16비트 little-endian PCM WAV**, 최대 4시간입니다. 입력 형식 변환과 마이크 녹음은 호출 앱이 맡습니다. 세션 호출은 겹치지 않아야 합니다. 오류가 나도 녹음기를 중단하지 말고, 같은 세션이나 같은 작업 폴더로 재시도하세요.

정상 녹음 종료 시 진행 중인 추론을 취소하지 않으면 모델과 처리 결과를 그대로 재사용할 수 있습니다. 작업 자체를 취소하면 실행 중인 엔진 프로세스를 종료하고 다음 요청에서 다시 로딩합니다. 여러 세션을 공유할 때 대기 중인 취소는 자신의 차례에 반영됩니다.

앱이 비정상 종료되어 WAV 헤더가 미완성이라면 `TranscriptionSession.recoverInterrupted(audio:directory:)`로 별도 복구 파일을 만들 수 있습니다. 이 코어의 녹음 표식이 있는 파일만 복구하며 원본은 덮어쓰지 않습니다.

## CLI

```sh
swift run doongdoong-transcribe audio.wav ./result \
  /opt/homebrew/bin/whisper-server /path/to/model.bin /path/to/vad.bin ko
```

`result/transcript.json`과 `result/local-transcription/`에 결과와 재개 기록을 저장합니다. 원본 파일과 작업 폴더를 함께 보관하면 다른 앱에서도 이어 처리할 수 있습니다.

## 검증과 한계

테스트는 녹음 중 증분 처리, 마지막 짧은 구간, 실패 후 재개, 음성 변경 검출, 언어별 캐시, 무음, 헤더 복구, 추론 직렬화, 취소 후 재시작을 확인합니다. 설치된 실제 엔진 검증은 `DD_WHISPER_SERVER`, `DD_WHISPER_MODEL`, `DD_WHISPER_VAD`, `DD_WHISPER_AUDIO`를 설정하고 `swift test --filter EngineTests/testInstalledEngineReusesModel`로 실행합니다.

M1·8GB에서 Turbo 모델에 8초 음성을 두 번 요청하여 동일 PID·모델 로딩 1회를 확인했습니다. 전체 73분 강의의 실시간 처리·발열·배터리·품질 회귀 검증을 대신하는 결과는 아닙니다. 짧은 구간 경계의 단어 손실, VAD 오검출, Whisper의 반복·환각은 여전히 평가해야 합니다. 입력을 겹쳐 반복 전사하지 않으므로 실시간 자막 수정 기능은 제공하지 않습니다.

이 패키지는 whisper.cpp의 Swift 프로세스 어댑터와 증분 전사 세션입니다. 음성 인식 모델을 자체 개발한 프로젝트는 아닙니다. 앱이 비정상 강제 종료되면 자식 엔진이 남을 수 있어 정상 종료 시 `unload()`를 호출해야 합니다.

MIT 라이선스. 외부 엔진과 모델의 출처·라이선스는 [구성요소 안내](THIRD_PARTY.md)에 정리했습니다.
