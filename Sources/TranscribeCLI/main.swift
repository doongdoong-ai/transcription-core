import Foundation
import DoongdoongTranscription

@main struct TranscribeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 || args.count == 6 else {
            print("Usage: doongdoong-transcribe <16k-mono.wav> <output-directory> <whisper-server> <model.bin> <vad.bin> [language]")
            exit(2)
        }
        let engine = WhisperEngine()
        do {
            let config = WhisperConfiguration(executable: URL(fileURLWithPath: args[2]), model: URL(fileURLWithPath: args[3]),
                                              vadModel: URL(fileURLWithPath: args[4]), language: args.count == 6 ? args[5] : "ko")
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
