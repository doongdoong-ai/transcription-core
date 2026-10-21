import Foundation
import Darwin

/// One growing or completed 16 kHz mono PCM WAV. The cache contains completed
/// chunks only. A failed request never advances the audio cursor.
public actor TranscriptionSession {
    struct Chunk: Codable {
        let start: Int64
        let end: Int64
        let sha256: String
        let segments: [SpeechSegment]
    }
    struct Checkpoint: Codable {
        let version: Int
        let identity: String
        var chunks: [Chunk]
    }
    private let audio: URL, directory: URL
    private let configuration: WhisperConfiguration
    private let recognizer: any SpeechRecognizer
    private var state: Checkpoint?
    private var busy = false

    public init(audio: URL, directory: URL, configuration: WhisperConfiguration, recognizer: any SpeechRecognizer) {
        self.audio = audio; self.directory = directory; self.configuration = configuration; self.recognizer = recognizer
    }

    /// Poll while recording. Pass final=true only after the recorder closes WAV.
    /// Calls for the same session must not overlap. Different sessions may share
    /// one WhisperEngine; it queues inference and keeps a single model resident.
    @discardableResult public func processAvailable(final: Bool) async throws -> [SpeechSegment] {
        guard !busy else { throw TranscriptionError.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let root = directory.appendingPathComponent("local-transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw TranscriptionError.checkpoint }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw TranscriptionError.busy }
        let marker = root.appendingPathComponent("recording-active")
        if !final { try Data().write(to: marker, options: .atomic) }
        let header = try PCMFile.header(audio, closed: final)
        let identity = try configuration.identity()
        let cache = root.appendingPathComponent(identity + ".json")
        if state == nil {
            if FileManager.default.fileExists(atPath: cache.path) {
                guard let size = try cache.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
                      let decoded = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: cache)),
                      decoded.version == 1, decoded.identity == identity else { throw TranscriptionError.checkpoint }
                try verify(decoded, header: header)
                state = decoded
            } else { state = Checkpoint(version: 1, identity: identity, chunks: []) }
        }
        guard var checkpoint = state, checkpoint.identity == identity else { throw TranscriptionError.configuration }
        if final { try verify(checkpoint, header: header) }
        let maximum = Int64(configuration.chunkSeconds) * PCMFile.sampleRate
        var start = checkpoint.chunks.last?.end ?? 0
        guard start <= header.frames else { throw TranscriptionError.sourceChanged }
        while header.frames - start >= maximum || final && start < header.frames {
            try Task.checkCancellation()
            var end = min(start + maximum, header.frames)
            if end - start == maximum {
                let left = max(start + maximum / 2, end - 5 * PCMFile.sampleRate)
                let tail = try PCMFile.samples(audio, header: header, start: left, end: end)
                if let cut = PCMFile.quietCut(tail, offset: left), cut > start { end = cut }
            }
            let pcm = try PCMFile.samples(audio, header: header, start: start, end: end)
            let segments: [SpeechSegment]
            // Digital silence never reaches the decoder. Quiet real speech still
            // goes through Silero VAD; do not use a coarse amplitude cutoff.
            if pcm.allSatisfy({ $0 == 0 }) { segments = [] }
            else {
                let raw = try await recognizer.transcribe(wave: PCMFile.wave(pcm), configuration: configuration)
                segments = try validated(raw, duration: Double(end - start) / 16000)
            }
            try Task.checkCancellation()
            guard digest(try PCMFile.samples(audio, header: header, start: start, end: end)) == digest(pcm) else { throw TranscriptionError.sourceChanged }
            checkpoint.chunks.append(Chunk(start: start, end: end, sha256: digest(pcm), segments: segments))
            try JSONEncoder().encode(checkpoint).write(to: cache, options: .atomic)
            state = checkpoint; start = end
        }
        if final { try? FileManager.default.removeItem(at: marker) }
        return checkpoint.chunks.flatMap { chunk in
            chunk.segments.map { .init(start: $0.start + Double(chunk.start) / 16000,
                                       end: $0.end + Double(chunk.start) / 16000, text: $0.text) }
        }
    }

    private func verify(_ checkpoint: Checkpoint, header: PCMFile.Header) throws {
        var previous: Int64 = 0
        for chunk in checkpoint.chunks {
            try Task.checkCancellation()
            guard chunk.start == previous, chunk.end > previous, chunk.end <= header.frames,
                  chunk.end - chunk.start <= Int64(configuration.chunkSeconds) * 16000 else { throw TranscriptionError.checkpoint }
            let pcm = try PCMFile.samples(audio, header: header, start: chunk.start, end: chunk.end)
            guard digest(pcm) == chunk.sha256 else { throw TranscriptionError.sourceChanged }
            _ = try validated(chunk.segments, duration: Double(chunk.end - chunk.start) / 16000)
            previous = chunk.end
        }
    }

    /// An interrupted recorder may leave zero RIFF/data sizes. Recover only when
    /// our live-session marker exists, and never overwrite the original.
    public static func recoverInterrupted(audio: URL, directory: URL) async throws -> URL? {
        let marker = directory.appendingPathComponent("local-transcription/recording-active")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let header = try PCMFile.header(audio, closed: false)
        guard !header.finalized, header.frames > 0 else { return nil }
        let output = directory.appendingPathComponent("audio-local-recovered.wav")
        let temporary = directory.appendingPathComponent(".recover-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: PCMFile.waveHeader(bytes: Int(header.frames * 2)),
                                             attributes: [.posixPermissions: 0o600]) else { throw TranscriptionError.invalidAudio }
        let writer = try FileHandle(forWritingTo: temporary); defer { try? writer.close() }
        try writer.seekToEnd()
        var cursor: Int64 = 0
        while cursor < header.frames {
            try Task.checkCancellation()
            let end = min(cursor + 300 * 16000, header.frames)
            try writer.write(contentsOf: PCMFile.samples(audio, header: header, start: cursor, end: end)); cursor = end
        }
        try writer.synchronize(); try writer.close()
        if FileManager.default.fileExists(atPath: output.path) {
            // Compare in bounded blocks, not by reading hours of audio into RAM.
            let a = try FileHandle(forReadingFrom: temporary), b = try FileHandle(forReadingFrom: output)
            defer { try? a.close(); try? b.close() }
            while true {
                let left = try a.read(upToCount: 1_048_576), right = try b.read(upToCount: 1_048_576)
                guard left == right else { throw TranscriptionError.sourceChanged }
                if left?.isEmpty != false { break }
            }
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
        return output
    }
}
