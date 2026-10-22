import Foundation
import CryptoKit

/// Uncorrected speech with timestamps measured by the recognizer, in seconds.
public struct SpeechSegment: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// Locale and checkpoint policy. Model assets belong to macOS, not the app.
public struct SpeechConfiguration: Codable, Equatable, Sendable {
    public let language: String
    public let chunkSeconds: Int

    public init(language: String = "ko", chunkSeconds: Int = 60) {
        self.language = language; self.chunkSeconds = chunkSeconds
    }

    public var localeIdentifier: String {
        ["ko": "ko-KR", "en": "en-US", "ja": "ja-JP"][language] ?? language
    }

    func validate() throws {
        guard (1...300).contains(chunkSeconds), !language.isEmpty, language != "auto",
              language.utf8.count <= 64,
              language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw TranscriptionError.configuration
        }
    }

    func identity() throws -> String {
        try validate()
        // Never reuse another engine's checkpoints. Pin segmentation policy too.
        // Apple's model revision is opaque; OS upgrades intentionally invalidate ASR caches.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return digest(Data("apple-speech-v1-phrases1|\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)|".utf8) + (try encoder.encode(self)))
    }
}

public enum SpeechAvailability: Equatable, Sendable {
    case ready, downloadRequired, downloading, unsupportedLanguage, unavailable
}

public enum SpeechPreparation: Equatable, Sendable {
    case checking, downloading(fraction: Double?)
}

public enum TranscriptionError: LocalizedError, Sendable {
    case configuration, invalidAudio, invalidResponse, sourceChanged, checkpoint, busy, unavailable, unsupportedLanguage, assetsUnavailable, timedOut, server(String)
    public var errorDescription: String? {
        switch self {
        case .configuration: "음성 인식 언어와 구간 길이를 확인해 주세요. 자동 언어 감지는 지원하지 않습니다."
        case .invalidAudio: "16 kHz, 모노, 16비트 PCM WAV 파일이 필요합니다."
        case .invalidResponse: "음성 인식 결과의 문장 또는 재생 위치를 확인할 수 없습니다."
        case .sourceChanged: "처리 중인 녹음의 기존 내용이 변경되었습니다. 원본과 전사 기록을 확인해 주세요."
        case .checkpoint: "저장된 전사 기록을 읽지 못했습니다. 원본 음성은 변경하지 않았습니다."
        case .busy: "같은 녹음의 처리가 이미 진행 중입니다."
        case .unavailable: "이 Mac에서는 Apple 음성 인식을 사용할 수 없습니다. macOS 26 이상과 지원 기기가 필요합니다."
        case .unsupportedLanguage: "선택한 언어는 이 Mac의 Apple 음성 인식에서 지원하지 않습니다."
        case .assetsUnavailable: "음성 인식 언어 모델을 준비하지 못했습니다. 인터넷 연결과 저장 공간을 확인하고 다시 시도해 주세요."
        case .timedOut: "음성 인식 응답 시간이 초과되었습니다. 저장된 구간부터 다시 시도할 수 있습니다."
        case .server(let message): "로컬 음성 인식 엔진: \(message)"
        }
    }
}

public protocol SpeechRecognizer: Sendable {
    func prepare(configuration: SpeechConfiguration, onProgress: (@Sendable (SpeechPreparation) async -> Void)?) async throws
    func transcribe(wave: Data, configuration: SpeechConfiguration) async throws -> [SpeechSegment]
}

public extension SpeechRecognizer {
    func prepare(configuration: SpeechConfiguration, onProgress: (@Sendable (SpeechPreparation) async -> Void)?) async throws {}
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Reject malformed timestamps instead of publishing invented playback positions.
func validated(_ segments: [SpeechSegment], duration: Double) throws -> [SpeechSegment] {
    var result: [SpeechSegment] = []
    var previous = 0.0
    for segment in segments {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
              segment.end >= segment.start, segment.start >= previous - 0.02,
              segment.end <= duration + 1 else { throw TranscriptionError.invalidResponse }
        previous = segment.end
        if text.isEmpty || text.hasPrefix("[_") { continue }
        let start = max(result.last?.end ?? 0, segment.start), end = min(duration, segment.end)
        guard end > start else { continue }
        result.append(.init(start: start, end: end, text: text))
    }
    return result
}
