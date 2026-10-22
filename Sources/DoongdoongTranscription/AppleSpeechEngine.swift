import Foundation
import Speech
import AVFoundation
import CoreMedia

/// On-device macOS speech recognition. No subprocess, account or uploaded audio.
/// The OS owns model storage and memory. A single gate serializes preparation,
/// inference and releasing the locale reservation across recording sessions.
public actor AppleSpeechEngine: SpeechRecognizer {
    private let gate = RecognitionGate()
    private var ownedReservation: Locale?
    private(set) var isAnalyzing = false

    public init() {}

    public static func availability(configuration: SpeechConfiguration = .init()) async -> SpeechAvailability {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard (try? configuration.validate()) != nil,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: configuration.localeIdentifier)) else {
            return .unsupportedLanguage
        }
        // On macOS 26, status(forModules:) may report .supported for an
        // installed but unreserved locale. Do not ask users to download it again.
        if await isInstalled(locale) { return .ready }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale)]) {
        case .installed: return .ready
        case .downloading: return .downloading
        case .supported: return .downloadRequired
        default: return .unsupportedLanguage
        }
    }

    public func prepare(configuration: SpeechConfiguration,
                        onProgress: (@Sendable (SpeechPreparation) async -> Void)? = nil) async throws {
        try await gate.acquire()
        do {
            _ = try await prepareLocked(configuration, onProgress: onProgress)
            await gate.release()
        } catch {
            await gate.release()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Release only reservations made by this engine, never other app assets.
    /// Model memory is reclaimed by macOS; this does not delete downloaded models.
    public func unload() async {
        do { try await gate.acquire() } catch { return }
        if let locale = ownedReservation {
            await AssetInventory.release(reservedLocale: locale); ownedReservation = nil
        }
        await gate.release()
    }

    public func transcribe(wave: Data, configuration: SpeechConfiguration) async throws -> [SpeechSegment] {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard wave.count >= 44, wave.count <= 300 * 32000 + 1_048_576 else { throw TranscriptionError.invalidAudio }
            let locale = try await prepareLocked(configuration, onProgress: nil)
            let result = try await analyze(wave, locale: locale)
            try Task.checkCancellation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    private static func isInstalled(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private func prepareLocked(_ configuration: SpeechConfiguration,
                               onProgress: (@Sendable (SpeechPreparation) async -> Void)?) async throws -> Locale {
        try Task.checkCancellation()
        try configuration.validate()
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: configuration.localeIdentifier)) else {
            throw TranscriptionError.unsupportedLanguage
        }
        await onProgress?(.checking)
        if let old = ownedReservation, old != locale {
            await AssetInventory.release(reservedLocale: old); ownedReservation = nil
        }
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            if try await AssetInventory.reserve(locale: locale) { ownedReservation = locale }
        }
        try Task.checkCancellation()
        let transcriber = Self.makeTranscriber(locale)
        if !(await Self.isInstalled(locale)) {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    await onProgress?(.downloading(fraction: nil))
                    let observer = Task {
                        while !Task.isCancelled {
                            let progress = request.progress
                            await onProgress?(.downloading(fraction: progress.totalUnitCount > 0 ? min(1, max(0, progress.fractionCompleted)) : nil))
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                        }
                    }
                    do {
                        try await withTaskCancellationHandler {
                            try await request.downloadAndInstall()
                        } onCancel: { request.progress.cancel() }
                        observer.cancel(); await observer.value
                    } catch {
                        observer.cancel(); await observer.value
                        throw error
                    }
                }
                try Task.checkCancellation()
                guard await Self.isInstalled(locale) else {
                    throw TranscriptionError.assetsUnavailable
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw TranscriptionError.assetsUnavailable
            }
        }
        return locale
    }

    private func analyze(_ wave: Data, locale: Locale) async throws -> [SpeechSegment] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("chunk.wav")
        try wave.write(to: audio)
        let header = try PCMFile.header(audio, closed: true)
        let duration = Double(header.frames) / 16000
        let transcriber = Self.makeTranscriber(locale)
        // Keep models warm between chunks, while allowing OS reclamation at idle.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        isAnalyzing = true
        defer { isAnalyzing = false }
        let reader = Task { () throws -> [SpeechSegment] in
            var segments: [SpeechSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let full = SpeechSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: String(result.text.characters))
                let runs = result.text.runs.compactMap { run -> SpeechSegment? in
                    guard let range = run.audioTimeRange else { return nil }
                    return .init(start: range.start.seconds, end: range.end.seconds, text: String(result.text[run.range].characters))
                }
                segments += SpeechPhrases.make(runs: runs, fallback: full)
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await withThrowingTaskGroup(of: [SpeechSegment].self) { group in
                    group.addTask {
                        let file = try AVAudioFile(forReading: audio)
                        if let last = try await analyzer.analyzeSequence(from: file) {
                            try await analyzer.finalizeAndFinish(through: last)
                        } else { await analyzer.cancelAndFinishNow() }
                        return try await reader.value
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(180))
                        throw TranscriptionError.timedOut
                    }
                    do {
                        let result = try await group.next() ?? []
                        group.cancelAll()
                        return result
                    } catch {
                        // Stop the system operation before the group waits for its
                        // children. Cancellation alone cannot unblock an OS stream.
                        group.cancelAll(); reader.cancel()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
                try Task.checkCancellation()
                return try validated(result, duration: duration)
            } catch {
                reader.cancel(); await analyzer.cancelAndFinishNow()
                _ = try? await reader.value
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
