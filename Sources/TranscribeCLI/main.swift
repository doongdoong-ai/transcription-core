import Foundation
import DoongdoongTranscription

@main struct TranscribeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 3 else {
            print("Usage: doongdoong-transcribe <16k-mono.wav> <output-directory> [language]")
            exit(2)
        }
        let engine = AppleSpeechEngine()
        do {
            let config = SpeechConfiguration(language: args.count == 3 ? args[2] : "ko")
            let output = URL(fileURLWithPath: args[1], isDirectory: true)
            let session = TranscriptionSession(audio: URL(fileURLWithPath: args[0]), directory: output, configuration: config, recognizer: engine)
            let segments = try await session.processAvailable(final: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(segments).write(to: output.appendingPathComponent("transcript.json"), options: .atomic)
            print("\(segments.count) segments → \(output.appendingPathComponent("transcript.json").path)")
            await engine.unload()
        } catch {
            await engine.unload()
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
