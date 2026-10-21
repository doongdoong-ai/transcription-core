import Foundation

/// Reads a growing AVAudioRecorder WAV without trusting its unfinished sizes.
enum PCMFile {
    static let sampleRate: Int64 = 16_000
    static let maximumFrames: Int64 = 4 * 3600 * sampleRate
    struct Header { let offset: UInt64; let frames: Int64; let finalized: Bool }

    static func header(_ url: URL, closed: Bool) throws -> Header {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard let data = try file.read(upToCount: Int(min(size, 1_048_576))), data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { throw TranscriptionError.invalidAudio }
        func number(_ at: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | UInt64(data[at + $1]) << ($1 * 8) }
        }
        var position = 12, valid = false
        while position + 8 <= data.count {
            let name = String(decoding: data[position..<position + 4], as: UTF8.self)
            let length = Int(number(position + 4, 4)), payload = position + 8
            if name == "fmt " {
                guard length >= 16, payload + 16 <= data.count else { throw TranscriptionError.invalidAudio }
                valid = number(payload, 2) == 1 && number(payload + 2, 2) == 1 && number(payload + 4, 4) == 16000
                    && number(payload + 12, 2) == 2 && number(payload + 14, 2) == 16
            }
            if name == "data" {
                guard valid, UInt64(payload) <= size else { throw TranscriptionError.invalidAudio }
                let available = size - UInt64(payload)
                let finalized = number(4, 4) + 8 == size && UInt64(length) <= available && length.isMultiple(of: 2)
                if closed && !finalized { throw TranscriptionError.invalidAudio }
                let bytes = finalized ? UInt64(length) : available
                let frames = Int64(bytes / 2)
                guard frames <= maximumFrames else { throw TranscriptionError.invalidAudio }
                return Header(offset: UInt64(payload), frames: frames, finalized: finalized)
            }
            guard length <= 1_048_576, payload + length <= data.count else { throw TranscriptionError.invalidAudio }
            position = payload + length + length % 2
        }
        throw TranscriptionError.invalidAudio
    }

    static func samples(_ url: URL, header: Header, start: Int64, end: Int64) throws -> Data {
        guard start >= 0, end > start, end <= header.frames, end - start <= 300 * sampleRate else { throw TranscriptionError.invalidAudio }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: header.offset + UInt64(start) * 2)
        let count = Int(end - start) * 2
        guard let data = try file.read(upToCount: count), data.count == count else { throw TranscriptionError.invalidAudio }
        return data
    }

    static func waveHeader(bytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); data.append(Data("data".utf8)); u32(UInt32(bytes))
        return data
    }
    static func wave(_ pcm: Data) -> Data { waveHeader(bytes: pcm.count) + pcm }

    /// Prefer the last >=260 ms pause in the final 5 seconds. Never duplicate
    /// already processed audio or cut an arbitrarily short final sentence away.
    static func quietCut(_ pcm: Data, offset: Int64) -> Int64? {
        let samples = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Double(Int16(littleEndian: $0)) / 32768 }
        }
        let window = 320
        var run: Int?, candidate: Int64?
        for start in stride(from: 0, to: samples.count, by: window) {
            let end = min(start + window, samples.count)
            let rms = sqrt(samples[start..<end].reduce(0) { $0 + $1 * $1 } / Double(end - start))
            if rms < 0.0126 {
                if run == nil { run = start }
                if let run, end - run >= 4160 { candidate = offset + Int64((run + end) / 2) }
            } else { run = nil }
        }
        return candidate
    }
}
