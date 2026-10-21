import Foundation
import CryptoKit

/// Uncorrected speech with timestamps measured by the recognizer, in seconds.
public struct SpeechSegment: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let timingQuality: String
    public let alignmentScore: Double?
    public init(start: Double, end: Double, text: String, timingQuality: String = "approximate", alignmentScore: Double? = nil) {
        self.start = start; self.end = end; self.text = text
        self.timingQuality = timingQuality; self.alignmentScore = alignmentScore
    }
}

public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public let codex: URL
    public let ffmpeg: URL
    public let python: URL
    public let alignmentModelDirectory: URL
    public let language: String
    public let chunkSeconds: Int

    public init(codex: URL, ffmpeg: URL, python: URL, alignmentModelDirectory: URL,
                language: String = "ko", chunkSeconds: Int = 300) {
        self.codex = codex; self.ffmpeg = ffmpeg; self.python = python
        self.alignmentModelDirectory = alignmentModelDirectory
        self.language = language; self.chunkSeconds = chunkSeconds
    }

    func validate() throws {
        guard (1...300).contains(chunkSeconds), ["ko", "en", "ja", "auto"].contains(language),
              [codex, ffmpeg, python].allSatisfy({ $0.isFileURL && FileManager.default.isExecutableFile(atPath: $0.path) }),
              alignmentModelDirectory.isFileURL,
              FileManager.default.isReadableFile(atPath: alignmentModelDirectory.appendingPathComponent("hub/checkpoints/model.pt").path)
        else { throw TranscriptionError.configuration }
    }

    func identity() throws -> String {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var value = "chatgpt-file-mms-v1|" + String(decoding: try encoder.encode(self), as: UTF8.self)
        for url in [codex, ffmpeg, python, alignmentModelDirectory.appendingPathComponent("hub/checkpoints/model.pt")] {
            let a = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            value += "|\(a[.size] ?? 0)|\(a[.modificationDate] as? Date ?? .distantPast)|\(a[.systemFileNumber] ?? 0)"
        }
        return digest(Data(value.utf8))
    }
}

public enum TranscriptionError: LocalizedError, Sendable {
    case configuration, invalidAudio, invalidResponse, sourceChanged, checkpoint, busy, server(String)
    public var errorDescription: String? {
        switch self {
        case .configuration: "Codex, FFmpeg와 재생 위치 정렬 도구를 확인해 주세요."
        case .invalidAudio: "16 kHz, 모노, 16비트 PCM WAV 파일이 필요합니다."
        case .invalidResponse: "음성 인식 결과의 문장 또는 재생 위치를 확인할 수 없습니다."
        case .sourceChanged: "처리 중인 녹음의 기존 내용이 변경되었습니다. 원본과 전사 기록을 확인해 주세요."
        case .checkpoint: "저장된 전사 기록을 읽지 못했습니다. 원본 음성은 변경하지 않았습니다."
        case .busy: "같은 녹음의 처리가 이미 진행 중입니다."
        case .server(let message): "음성 처리: \(message)"
        }
    }
}

public protocol SpeechRecognizer: Sendable {
    func transcribe(wave: Data, configuration: TranscriptionConfiguration, workspace: URL) async throws -> [SpeechSegment]
    func transcribe(wave: Data, configuration: TranscriptionConfiguration, workspace: URL,
                    onPhase: (@Sendable (SpeechProcessingPhase) async -> Void)?) async throws -> [SpeechSegment]
}

public extension SpeechRecognizer {
    func transcribe(wave: Data, configuration: TranscriptionConfiguration, workspace: URL,
                    onPhase: (@Sendable (SpeechProcessingPhase) async -> Void)?) async throws -> [SpeechSegment] {
        try await transcribe(wave: wave, configuration: configuration, workspace: workspace)
    }
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
              segment.end <= duration + 1, ["aligned", "approximate"].contains(segment.timingQuality) else { throw TranscriptionError.invalidResponse }
        previous = segment.end
        if text.isEmpty || text.hasPrefix("[_") { continue }
        let start = max(result.last?.end ?? 0, segment.start), end = min(duration, segment.end)
        guard end > start else { continue }
        result.append(.init(start: start, end: end, text: text, timingQuality: segment.timingQuality, alignmentScore: segment.alignmentScore))
    }
    return result
}
