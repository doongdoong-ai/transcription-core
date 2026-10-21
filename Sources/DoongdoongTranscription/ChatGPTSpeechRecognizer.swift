import Foundation

/// Completed audio files go to ChatGPT dictation. Codex supplies login only;
/// no model turn is started. Raw responses survive alignment failure/cancellation.
public actor ChatGPTSpeechRecognizer: SpeechRecognizer {
    public static let shared = ChatGPTSpeechRecognizer()
    private var active = false
    public init() {}

    public func transcribe(wave: Data, configuration: TranscriptionConfiguration, workspace: URL) async throws -> [SpeechSegment] {
        try await transcribe(wave: wave, configuration: configuration, workspace: workspace, onPhase: nil)
    }

    public func transcribe(wave: Data, configuration: TranscriptionConfiguration, workspace: URL,
                           onPhase: (@Sendable (SpeechProcessingPhase) async -> Void)?) async throws -> [SpeechSegment] {
        // Serialize acoustic alignment to avoid loading several large models on an 8 GB Mac.
        while active { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        active = true; defer { active = false }
        try configuration.validate()
        await onPhase?(.recognition)
        guard wave.count > 44 else { throw TranscriptionError.invalidAudio }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let audio = workspace.appendingPathComponent("audio.wav")
        let encoded = workspace.appendingPathComponent("audio.m4a")
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: encoded) }
        try wave.write(to: audio, options: .atomic)
        let duration = Double(try PCMFile.header(audio, closed: true).frames) / 16000
        let rawURL = workspace.appendingPathComponent("dictation.json")
        struct Raw: Codable { let audioHash: String; let language: String; let text: String }
        let hash = digest(wave)
        let raw: Raw
        if FileManager.default.fileExists(atPath: rawURL.path) {
            guard let bytes = try rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 4 * 1024 * 1024 else {
                throw TranscriptionError.checkpoint
            }
            raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf: rawURL))
            guard raw.audioHash == hash, raw.language == configuration.language, !raw.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.sourceChanged
            }
        } else {
            try await MediaProcessRunner().run(executable: configuration.ffmpeg,
                arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", audio.path,
                            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "32k", encoded.path],
                directory: workspace, log: workspace.appendingPathComponent("encode.log"), timeout: 120)
            let text = try await Self.dictate(encoded: encoded, configuration: configuration, workspace: workspace)
            raw = Raw(audioHash: hash, language: configuration.language, text: text)
            try JSONEncoder().encode(raw).write(to: rawURL, options: .atomic)
        }
        try Task.checkCancellation()
        await onPhase?(.alignment)
        let aligned = workspace.appendingPathComponent("alignment.json")
        if FileManager.default.fileExists(atPath: aligned.path) {
            return try SpeechAlignment.decode(Data(contentsOf: aligned), text: raw.text, duration: duration)
        }
        let temporary = workspace.appendingPathComponent("alignment.pending.json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await MediaProcessRunner().run(executable: configuration.python,
            arguments: [SpeechAlignment.helper.path, "--watch-parent", "--audio", audio.path, "--transcript", rawURL.path,
                        "--output", temporary.path, "--model-directory", configuration.alignmentModelDirectory.path,
                        "--language", configuration.language, "--cache-directory", workspace.appendingPathComponent("acoustic-cache").path],
            directory: workspace, log: workspace.appendingPathComponent("alignment.log"), timeout: max(300, duration * 6))
        let data = try Data(contentsOf: temporary)
        let segments = try SpeechAlignment.decode(data, text: raw.text, duration: duration)
        try Task.checkCancellation()
        try data.write(to: aligned, options: .atomic)
        return segments
    }

    @MainActor private static func dictate(encoded: URL, configuration: TranscriptionConfiguration, workspace: URL) async throws -> String {
        let client = DictationAccountClient()
        defer { client.stop() }
        return try await withTaskCancellationHandler {
            try await client.start(executable: configuration.codex, workingDirectory: workspace)
            let account = try await client.request(method: "account/read", params: ["refreshToken": false])
            guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else { throw DictationError.login }
            func upload(refresh: Bool) async throws -> String {
                let auth = try await client.request(method: "getAuthStatus", params: ["includeToken": true, "refreshToken": refresh])
                guard auth["authMethod"] as? String == "chatgpt", let token = auth["authToken"] as? String else { throw DictationError.login }
                return try await DictationClient().transcribe(m4a: encoded, language: configuration.language,
                    credentials: DictationCredentials(token: token), workspace: workspace)
            }
            do { return try await upload(refresh: false) }
            catch DictationError.login { return try await upload(refresh: true) }
        } onCancel: { Task { @MainActor in client.stop() } }
    }
}
