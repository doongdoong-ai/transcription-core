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

public struct WhisperConfiguration: Codable, Equatable, Sendable {
    public let executable: URL
    public let model: URL
    public let vadModel: URL
    public let language: String
    public let chunkSeconds: Int

    public init(executable: URL, model: URL, vadModel: URL, language: String = "ko", chunkSeconds: Int = 60) {
        self.executable = executable; self.model = model; self.vadModel = vadModel
        self.language = language; self.chunkSeconds = chunkSeconds
    }

    func validate() throws {
        guard (1...300).contains(chunkSeconds), !language.isEmpty,
              language.utf8.count <= 16, language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }),
              executable.isFileURL, model.isFileURL, vadModel.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: model.path),
              FileManager.default.isReadableFile(atPath: vadModel.path) else { throw TranscriptionError.configuration }
    }

    // File identity includes replacement and modification, without rereading GB of
    // weights for each poll. Do not modify a model in place while a session is active.
    func identity() throws -> String {
        try validate()
        // JSON field ordering is not stable across processes; use sorted keys.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var value = "whisper-server-v1|" + String(decoding: try encoder.encode(self), as: UTF8.self)
        for url in [executable, model, vadModel] {
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
        case .configuration: "로컬 음성 인식 엔진과 모델 파일을 확인해 주세요."
        case .invalidAudio: "16 kHz, 모노, 16비트 PCM WAV 파일이 필요합니다."
        case .invalidResponse: "음성 인식 결과의 문장 또는 재생 위치를 확인할 수 없습니다."
        case .sourceChanged: "처리 중인 녹음의 기존 내용이 변경되었습니다. 원본과 전사 기록을 확인해 주세요."
        case .checkpoint: "저장된 전사 기록을 읽지 못했습니다. 원본 음성은 변경하지 않았습니다."
        case .busy: "같은 녹음의 처리가 이미 진행 중입니다."
        case .server(let message): "로컬 음성 인식 엔진: \(message)"
        }
    }
}

public protocol SpeechRecognizer: Sendable {
    func transcribe(wave: Data, configuration: WhisperConfiguration) async throws -> [SpeechSegment]
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
