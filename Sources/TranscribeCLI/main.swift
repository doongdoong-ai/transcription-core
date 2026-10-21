import Foundation
import DoongdoongTranscription

@main struct Transcribe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard (6...7).contains(args.count) else {
            print("Usage: doongdoong-transcribe AUDIO.wav OUTPUT_DIRECTORY CODEX FFMPEG PYTHON ALIGNMENT_MODELS [LANGUAGE]")
            exit(2)
        }
        let output = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let config = TranscriptionConfiguration(codex: URL(fileURLWithPath: args[2]), ffmpeg: URL(fileURLWithPath: args[3]),
            python: URL(fileURLWithPath: args[4]), alignmentModelDirectory: URL(fileURLWithPath: args[5]), language: args.count > 6 ? args[6] : "ko")
        let session = TranscriptionSession(audio: URL(fileURLWithPath: args[0]), directory: output,
            configuration: config, recognizer: ChatGPTSpeechRecognizer.shared)
        let result = try await session.processAvailable(final: true) { value in
            print("Processed \(Int(value.processedSeconds))/\(Int(value.totalSeconds)) seconds")
        }
        try JSONEncoder().encode(result).write(to: output.appendingPathComponent("segments.json"), options: .atomic)
    }
}
