import Foundation
import XCTest
@testable import DoongdoongTranscription

final class AppleSpeechTests: XCTestCase, @unchecked Sendable {
    func testPhrasesPreserveEveryCharacterAndUseOnlyNativeBoundaries() throws {
        let runs: [SpeechSegment] = [
            .init(start: 1, end: 2, text: "시험은 "), .init(start: 2, end: 4, text: "없습니다."),
            .init(start: 5, end: 6, text: " 금액은"), .init(start: 6, end: 8, text: " 10,000원입니다.")
        ]
        let fallback = SpeechSegment(start: 0, end: 10, text: runs.map(\.text).joined())
        let result = SpeechPhrases.make(runs: runs, fallback: fallback)
        XCTAssertEqual(result.map(\.text).joined(), fallback.text)
        XCTAssertEqual(result.map(\.start), [1, 5]); XCTAssertEqual(result.map(\.end), [4, 8])
        XCTAssertEqual(try validated(result, duration: 10).count, 2)
    }

    func testMissingOrInvalidRunTimingFallsBackWithoutDroppingWords() {
        let fallback = SpeechSegment(start: 0, end: 10, text: "중요한 시험 안내입니다.")
        XCTAssertEqual(SpeechPhrases.make(runs: [.init(start: 2, end: 5, text: "시험 안내입니다.")], fallback: fallback), [fallback])
        XCTAssertEqual(SpeechPhrases.make(runs: [.init(start: .nan, end: 5, text: fallback.text)], fallback: fallback), [fallback])
        XCTAssertEqual(SpeechPhrases.make(runs: [], fallback: fallback), [fallback])
    }

    func testConfigurationRejectsAutoAndSeparatesLanguagesAndChunkPolicy() throws {
        XCTAssertThrowsError(try SpeechConfiguration(language: "auto").validate())
        XCTAssertThrowsError(try SpeechConfiguration(chunkSeconds: 301).validate())
        XCTAssertEqual(SpeechConfiguration(language: "ko").localeIdentifier, "ko-KR")
        XCTAssertNotEqual(try SpeechConfiguration().identity(), try SpeechConfiguration(language: "en").identity())
        XCTAssertNotEqual(try SpeechConfiguration().identity(), try SpeechConfiguration(chunkSeconds: 120).identity())
    }

    private actor Counter {
        var active = 0, peak = 0, finished = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1; finished += 1 }
    }
    func testReentrantCallersNeverOverlapAndCancelledWaitersDoNotBlockQueue() async throws {
        let gate = RecognitionGate(), counter = Counter()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire(); await gate.release() }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected a cancelled queued waiter") } catch is CancellationError {}
        await gate.release()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.acquire()
                    await counter.enter()
                    try await Task.sleep(for: .milliseconds(10))
                    await counter.leave(); await gate.release()
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak, finished = await counter.finished
        XCTAssertEqual(peak, 1); XCTAssertEqual(finished, 8)
    }

    /// Opt-in only: CI must never download models or depend on speech hardware.
    func testInstalledAppleEngineTranscribesCancelsAndRestarts() async throws {
        guard let path = ProcessInfo.processInfo.environment["DD_APPLE_SPEECH_AUDIO"] else {
            throw XCTSkip("Set DD_APPLE_SPEECH_AUDIO to test an installed language model")
        }
        let configuration = SpeechConfiguration()
        guard await AppleSpeechEngine.availability(configuration: configuration) == .ready else {
            throw XCTSkip("Korean Apple model is not installed; no download in tests")
        }
        let engine = AppleSpeechEngine(), wave = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            let first = try await engine.transcribe(wave: wave, configuration: configuration)
            XCTAssertFalse(first.isEmpty)
            let cancelled = Task { try await engine.transcribe(wave: wave, configuration: configuration) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await engine.isAnalyzing) {
                guard ContinuousClock.now < deadline else { cancelled.cancel(); throw TranscriptionError.timedOut }
                try await Task.sleep(for: .milliseconds(2))
            }
            cancelled.cancel()
            do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
            let second = try await engine.transcribe(wave: wave, configuration: configuration)
            XCTAssertFalse(second.isEmpty)
            XCTAssertTrue(second.allSatisfy { $0.start.isFinite && $0.end > $0.start })
            await engine.unload()
        } catch { await engine.unload(); throw error }
    }
}
