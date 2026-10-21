import Foundation

/// Forced alignment maps existing text to audio. It does not generate or correct words.
public enum SpeechAlignment {
    public static var helper: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("DoongdoongTranscription_DoongdoongTranscription.bundle/Resources/align_transcript.py")
            if FileManager.default.isReadableFile(atPath: bundled.path) { return bundled }
        }
        return Bundle.module.resourceURL!.appendingPathComponent("align_transcript.py")
    }

    public static func decode(_ data: Data, text: String, duration: Double) throws -> [SpeechSegment] {
        struct Document: Decodable {
            struct Segment: Decodable {
                let id: Int
                let start: Double
                let end: Double
                let text: String
                let originalText: String
                let timingQuality: String
                let alignmentScore: Double?
            }
            let schemaVersion: Int
            let method: String
            let duration: Double
            let text: String
            let segments: [Segment]
        }
        guard data.count <= 16 * 1024 * 1024, duration.isFinite, duration > 0 else { throw TranscriptionError.invalidResponse }
        let value = try JSONDecoder().decode(Document.self, from: data)
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        guard value.schemaVersion == 2, value.method == "mms-ctc-forced-alignment",
              value.duration.isFinite, abs(value.duration - duration) < 0.1,
              value.text == text, !value.segments.isEmpty,
              compact(value.segments.map(\.text).joined()) == compact(text) else { throw TranscriptionError.invalidResponse }
        var end = 0.0
        for (index, segment) in value.segments.enumerated() {
            guard segment.id == index, segment.start.isFinite, segment.end.isFinite,
                  segment.start >= end, segment.end > segment.start, segment.end <= duration,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.originalText == segment.text,
                  ["aligned", "approximate"].contains(segment.timingQuality),
                  segment.alignmentScore.map(\.isFinite) ?? true else { throw TranscriptionError.invalidResponse }
            end = segment.end
        }
        return value.segments.map { .init(start: $0.start, end: $0.end, text: $0.text,
            timingQuality: $0.timingQuality, alignmentScore: $0.alignmentScore) }
    }
}
