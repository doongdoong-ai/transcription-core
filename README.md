# 둥둥이 전사 코어

**macOS의 Apple Speech로 음성을 텍스트와 재생 위치로 바꾸는 독립 Swift 패키지입니다.** 녹음 중 저장되는 WAV와 녹음이 끝난 파일에 같은 증분 처리 경로를 사용합니다. Codex·로그인·앱 UI에 의존하지 않습니다.

macOS 26 이상, Swift 6.2 / macOS 26 SDK가 필요합니다. Apple Silicon M1에서 검증했습니다. 지원 기기와 언어는 `AppleSpeechEngine.availability`로 확인합니다. 음성은 `SpeechAnalyzer`와 `SpeechTranscriber`가 기기에서 처리하고, 언어 모델은 macOS의 `AssetInventory`가 설치·관리합니다. 첫 사용에 모델 다운로드가 필요할 수 있습니다.

## 파일을 전사하기

```swift
import DoongdoongTranscription

let engine = AppleSpeechEngine()
let configuration = SpeechConfiguration(language: "ko", chunkSeconds: 60)
let session = TranscriptionSession(
    audio: audioURL, directory: workDirectory,
    configuration: configuration, recognizer: engine)
let segments = try await session.processAvailable(final: true) { progress in
    // preparation: 언어 모델 확인·다운로드, 그 외: 완료된 음성 길이
    print(progress.processedSeconds, progress.totalSeconds, progress.preparation as Any)
}
await engine.unload()
```

입력은 16 kHz·모노·16비트 PCM WAV입니다. 출력 `SpeechSegment`는 `start`, `end`, `text`를 갖습니다. 시각은 원본 음성 기준 초 단위입니다. Apple이 반환한 시간 속성 텍스트를 문장부호·길이·시간 기준으로 묶고, 시간 속성이 빠지면 Apple의 결과 구간을 그대로 사용합니다. 임의로 단어별 시간을 추정하지 않습니다.

`language`는 `ko`/`ko-KR`, `en`/`en-US`, `ja`/`ja-JP` 같은 명시적 언어입니다. 실제 지원 언어는 시스템에서 확인합니다. 자동 감지는 지원하지 않습니다.

## 녹음 중 처리와 복구

1. 녹음기를 열기 전에 `TranscriptionSession.prepareRecording(directory:)`를 호출합니다.
2. WAV가 자라는 동안 같은 세션의 `processAvailable(final: false)`를 주기적으로 호출합니다.
3. 녹음기를 닫은 뒤 `final: true`로 남은 구간을 처리합니다.
4. 중단된 WAV는 `recoverInterrupted(audio:directory:)`로 원본과 별도 파일에 복구합니다.

기본 구간은 최대 60초이며 마지막 5초의 쉼을 우선 경계로 택합니다. 겹친 음성을 반복 처리하지 않고, 짧은 마지막 구간도 남기지 않습니다. 디지털 무음은 인식기에 보내지 않으며, 작은 발화는 진폭 기준으로 제거하지 않습니다.

완료된 구간만 PCM SHA-256과 함께 원자적으로 저장합니다. 실패·취소는 현재 구간의 커서를 전진시키지 않습니다. 중복 작업은 파일 잠금으로 막으며, 소스가 바뀌면 기존 결과를 재사용하지 않습니다. 체크포인트는 엔진·분할 정책·언어·OS 버전으로 구분합니다. Apple 모델의 독립 revision은 API에서 확보하지 못하므로 같은 OS에서의 모델 업데이트까지 감지한다고 보장하지 않습니다.

하나의 `AppleSpeechEngine`을 여러 세션이 공유할 수 있습니다. FIFO gate가 준비와 추론을 직렬화하며 대기 중 취소도 처리합니다. 각 분석은 180초 제한을 두고 취소 시 `cancelAndFinishNow()`로 정리합니다. `.lingering` 정책으로 구간 사이 모델 재사용을 시스템에 맡깁니다. `unload()`는 이 엔진이 예약한 언어만 해제하며, 모델 파일을 삭제하거나 시스템 메모리의 즉시 반환을 보장하지 않습니다.

## 언어 모델 준비

`availability(configuration:)`는 준비 완료·다운로드 필요·다운로드 중·미지원 언어·미지원 기기를 구분합니다. `prepare(configuration:onProgress:)`로 사전 준비할 수 있으며, `TranscriptionSession`도 첫 미처리 발화 전에 준비합니다. 다운로드 오류가 나면 작업은 체크포인트를 보존하고 재시도할 수 있습니다. 음성 전사에는 계정이나 외부 음성 API가 필요 없습니다. 텍스트 교정·요약은 호출 앱의 책임입니다.

## CLI와 검증

```sh
swift test
swift run -c release doongdoong-transcribe /path/lecture.wav /path/work ko
```

결과는 작업 폴더의 `transcript.json`과 `local-transcription/`에 저장합니다. 언어 모델이 없으면 첫 실행에서 다운로드합니다. 일반 테스트는 모델을 다운로드하거나 음성을 재생하지 않습니다. 설치된 한국어 모델의 실제 전사·취소·재시도 검증은 `DD_APPLE_SPEECH_AUDIO=/path/sample.wav swift test --filter AppleSpeechTests/testInstalledAppleEngine`로 실행합니다.

0.3.0은 기존 엔진 설정 API를 교체합니다. Whisper 실행 파일·GGML 모델·Silero VAD·localhost 서버·모델 설치 스크립트가 제거되었습니다. 기존 저장 음성은 새 엔진으로 다시 처리하며 예전 엔진 체크포인트와 섞지 않습니다. 복구 기준은 [이전 엔진 복구 지침](docs/restore-whisper.ko.md)에 남겨 두었습니다.

이 패키지는 Apple 음성 모델을 자체 개발하거나 재배포하지 않습니다. 패키지 코드는 MIT이며 시스템 프레임워크·모델에는 Apple의 조건이 적용됩니다. [외부 구성요소](THIRD_PARTY.md)를 확인하세요.
