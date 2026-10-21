import Foundation
import XCTest
@testable import DoongdoongTranscription

private actor Recognizer: SpeechRecognizer {
    var calls = 0
    var failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func transcribe(wave: Data, configuration: WhisperConfiguration) async throws -> [SpeechSegment] {
        calls += 1
        if calls == failAt { throw TranscriptionError.server("fixture") }
        let duration = Double(wave.count - 44) / 32000
        return [.init(start: 0, end: duration, text: "강의 \(calls)")]
    }
}

final class SessionTests: XCTestCase, @unchecked Sendable {
    private actor Events {
        var values: [TranscriptionProgress] = []
        func append(_ value: TranscriptionProgress) { values.append(value) }
    }
    func testProgressCountsOnlyCommittedAudioAndRestoresCachedCoverage() async throws {
        let (root, audio, config) = try fixture(seconds: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Events()
        do {
            _ = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: Recognizer(failAt: 2))
                .processAvailable(final: true) { await first.append($0) }
            XCTFail("Expected failure")
        } catch {}
        let partial = await first.values
        XCTAssertEqual(partial.map(\.processedSeconds), [0, 2])
        let next = Events()
        _ = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: Recognizer())
            .processAvailable(final: true) { await next.append($0) }
        let resumed = await next.values
        XCTAssertEqual(resumed.map(\.processedSeconds), [2, 4, 5])
        XCTAssertEqual(resumed.map(\.completedChunks), [1, 2, 3])
        XCTAssertEqual(resumed.last?.fraction, 1)
    }
    func fixture(seconds: Double) throws -> (URL, URL, WhisperConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("model.bin"); try Data([1]).write(to: model)
        let audio = root.appendingPathComponent("audio.wav")
        try PCMFile.wave(samples(seconds)).write(to: audio)
        return (root, audio, WhisperConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), model: model, vadModel: model, chunkSeconds: 2))
    }
    func samples(_ seconds: Double) -> Data {
        var result = Data()
        for index in 0..<Int(seconds * 16000) {
            var value = Int16(sin(Double(index) * 0.1) * 10000).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }

    func testGrowingFileProcessesOnlyNewAudioAndKeepsShortTail() async throws {
        let (root, audio, config) = try fixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        // Unfinished header: recorder has not updated the sizes yet.
        try (PCMFile.waveHeader(bytes: 0) + samples(2)).write(to: audio)
        let backend = Recognizer()
        let session = TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend)
        let first = try await session.processAvailable(final: false)
        XCTAssertEqual(first.count, 1)
        _ = try await session.processAvailable(final: false)
        let calls = await backend.calls; XCTAssertEqual(calls, 1)
        try PCMFile.wave(samples(4.25)).write(to: audio)
        let finished = try await session.processAvailable(final: true)
        XCTAssertEqual(finished.map(\.start), [0, 2, 4])
        XCTAssertEqual(finished.last?.end, 4.25)
        let total = await backend.calls; XCTAssertEqual(total, 3)
        let fresh = Recognizer(failAt: 1)
        let resumed = TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: fresh)
        let cached = try await resumed.processAvailable(final: true)
        XCTAssertEqual(cached, finished)
        let repeatCalls = await fresh.calls; XCTAssertEqual(repeatCalls, 0)
    }

    func testFailedChunkResumesWithoutRepeatingCompletedAudio() async throws {
        let (root, audio, config) = try fixture(seconds: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = Recognizer(failAt: 2)
        let first = TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: broken)
        do { try await first.processAvailable(final: true); XCTFail("Expected failure") } catch {}
        let backend = Recognizer()
        let resumed = TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend)
        let result = try await resumed.processAvailable(final: true)
        let calls = await backend.calls; XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.map(\.start), [0, 2, 4])
        XCTAssertEqual(result.last?.end, 5)
    }

    func testChangedAudioCannotReuseCheckpoint() async throws {
        let (root, audio, config) = try fixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = Recognizer()
        _ = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend).processAvailable(final: true)
        var bytes = try Data(contentsOf: audio); bytes[50] ^= 0xff; try bytes.write(to: audio)
        do {
            try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend).processAvailable(final: true)
            XCTFail("Expected changed audio rejection")
        } catch TranscriptionError.sourceChanged {} catch { XCTFail("\(error)") }
    }

    func testLanguageChangeUsesSeparateCheckpoint() async throws {
        let (root, audio, config) = try fixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = Recognizer()
        _ = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend).processAvailable(final: true)
        let other = WhisperConfiguration(executable: config.executable, model: config.model, vadModel: config.vadModel, language: "en", chunkSeconds: 2)
        _ = try await TranscriptionSession(audio: audio, directory: root, configuration: other, recognizer: backend).processAvailable(final: true)
        let calls = await backend.calls; XCTAssertEqual(calls, 2)
    }

    func testDigitalSilenceDoesNotInvokeDecoder() async throws {
        let (root, audio, config) = try fixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        try PCMFile.wave(Data(repeating: 0, count: 64000)).write(to: audio)
        let backend = Recognizer()
        let result = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: backend).processAvailable(final: true)
        XCTAssertTrue(result.isEmpty)
        let calls = await backend.calls; XCTAssertEqual(calls, 0)
    }

    func testRecoveryNeverOverwritesUnfinishedOriginal() async throws {
        let (root, audio, config) = try fixture(seconds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = PCMFile.waveHeader(bytes: 0) + samples(2)
        try original.write(to: audio)
        _ = try await TranscriptionSession(audio: audio, directory: root, configuration: config, recognizer: Recognizer()).processAvailable(final: false)
        let repaired = try await TranscriptionSession.recoverInterrupted(audio: audio, directory: root)
        XCTAssertNotNil(repaired)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        XCTAssertEqual(try PCMFile.header(XCTUnwrap(repaired), closed: true).frames, 32000)
        let again = try await TranscriptionSession.recoverInterrupted(audio: audio, directory: root)
        XCTAssertEqual(again, repaired)
    }

    func testInvalidTimestampsAreRejected() throws {
        XCTAssertThrowsError(try validated([.init(start: 2, end: 1, text: "bad")], duration: 5))
        XCTAssertThrowsError(try validated([.init(start: 0, end: 20, text: "bad")], duration: 5))
        XCTAssertThrowsError(try validated([.init(start: .nan, end: 1, text: "bad")], duration: 5))
    }

    func testQuietBoundaryStaysInsidePause() {
        let pcm = samples(1) + Data(repeating: 0, count: 16000) + samples(0.5)
        let cut = PCMFile.quietCut(pcm, offset: 16000)
        XCTAssertNotNil(cut)
        XCTAssertGreaterThan(try! XCTUnwrap(cut), 32000)
        XCTAssertLessThan(try! XCTUnwrap(cut), 40000)
    }
}
