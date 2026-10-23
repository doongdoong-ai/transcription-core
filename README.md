# Transcription Core

Apple Speech로 음성을 텍스트와 타임스탬프로 변환하는 Swift 패키지입니다. 둥둥이의 음성 인식에 사용하며, 녹음 중 처리와 중단 후 이어하기를 지원합니다.

## 요구 사항

- macOS 26 이상, Swift 6.2 이상, macOS 26 SDK
- 16 kHz·모노·16비트 PCM WAV, 최대 4시간

음성 인식은 기기에서 실행되며 계정이나 API 키가 필요 없습니다. 언어 모델은 macOS가 관리하고, 첫 사용 시 다운로드가 필요할 수 있습니다. 지원 기기와 언어는 `AppleSpeechEngine.availability(configuration:)`로 확인합니다. 언어는 직접 지정하며 자동 감지는 지원하지 않습니다.

## 설치

`Package.swift`의 `dependencies`에 추가합니다.

```swift
.package(url: "https://github.com/doongdoong-ai/transcription-core.git", from: "0.3.0")
```

사용할 타깃의 `dependencies`에도 제품을 추가합니다.

```swift
.product(name: "DoongdoongTranscription", package: "transcription-core")
```

## 파일 전사

```swift
import Foundation
import DoongdoongTranscription

func transcribe(audio: URL, directory: URL, engine: AppleSpeechEngine) async throws -> [SpeechSegment] {
    let session = TranscriptionSession(
        audio: audio,
        directory: directory,
        configuration: .init(language: "ko"),
        recognizer: engine
    )
    return try await session.processAvailable(final: true)
}
```

`AppleSpeechEngine()`을 만들어 전달합니다. 여러 세션에서 공유할 수 있으며, 사용을 마치면 `await engine.unload()`로 언어 모델 예약을 해제합니다.

`SpeechSegment`는 `start`, `end`, `text`를 담습니다. 시간은 원본 음성 기준 초 단위입니다. `processAvailable`의 진행 콜백에서 모델 준비 상태와 처리한 음성 길이를 받을 수 있습니다.

완료한 구간은 작업 폴더에 저장됩니다. 같은 음성·설정·작업 폴더로 다시 호출하면 저장된 구간을 재사용합니다. 텍스트 교정과 요약은 호출 앱에서 처리합니다.

## 녹음 중 처리

1. 녹음 시작 전 `TranscriptionSession.prepareRecording(directory:)`를 호출합니다.
2. 녹음 중 같은 세션에 `processAvailable(final: false)`를 주기적으로 호출합니다.
3. 녹음 파일을 닫은 뒤 `final: true`로 나머지를 처리합니다.

호출 주기는 앱에서 정합니다. `chunkSeconds`는 한 번에 인식·저장할 구간의 최대 길이이며 기본 60초입니다. 두 설정은 별개입니다. 비정상 종료로 WAV 헤더가 완성되지 않았다면 `recoverInterrupted(audio:directory:)`로 별도 파일에 복구할 수 있습니다.

## CLI·개발

저장소에서 실행합니다.

```sh
swift run -c release doongdoong-transcribe /path/lecture.wav /path/work ko
swift test
swift build -c release
```

CLI 결과는 작업 폴더의 `transcript.json`, 이어하기 데이터는 `local-transcription/`에 저장됩니다. 기본 테스트는 언어 모델을 다운로드하거나 실제 음성을 인식하지 않습니다.

[MIT License](LICENSE) · [외부 구성요소](THIRD_PARTY.md) · [이전 Whisper 엔진 복구](docs/restore-whisper.ko.md)
