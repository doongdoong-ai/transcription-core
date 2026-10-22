import Foundation

/// Group native timed text into readable phrases without inventing word times.
enum SpeechPhrases {
    static func make(runs: [SpeechSegment], fallback: SpeechSegment) -> [SpeechSegment] {
        guard !runs.isEmpty, runs.map(\.text).joined() == fallback.text else { return [fallback] }
        var phrases: [SpeechSegment] = []
        var text = "", start = 0.0, end = 0.0
        var previousEnd = fallback.start
        func flush() {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { text = ""; return }
            phrases.append(.init(start: start, end: end, text: text)); text = ""
        }
        for run in runs {
            guard run.start.isFinite, run.end.isFinite, run.end > run.start,
                  run.start >= fallback.start - 0.02, run.end <= fallback.end + 0.02,
                  run.start >= previousEnd - 0.02 else { return [fallback] }
            previousEnd = run.end
            if text.isEmpty { start = run.start }
            text += run.text; end = run.end
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= 100 || end - start >= 12 || trimmed.last.map({ ".!?。！？".contains($0) }) == true { flush() }
        }
        flush()
        return phrases
    }
}
