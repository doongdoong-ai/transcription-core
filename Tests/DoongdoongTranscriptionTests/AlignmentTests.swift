import XCTest
@testable import DoongdoongTranscription

final class AlignmentTests: XCTestCase {
    private func document(_ overrides: [String: Any] = [:]) throws -> Data {
        var segment: [String: Any] = ["id": 0, "start": 0.2, "end": 0.8, "text": "원문입니다.",
            "originalText": "원문입니다.", "timingQuality": "aligned", "alignmentScore": -1.0]
        for (key, value) in overrides { segment[key] = value }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "method": "mms-ctc-forced-alignment",
            "duration": 1, "text": "원문입니다.", "segments": [segment]])
    }
    func testHelperIsPackagedAndAlignmentRetainsSourceAndUncertainty() throws {
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: SpeechAlignment.helper.path))
        let segments = try SpeechAlignment.decode(document(["timingQuality": "approximate"]), text: "원문입니다.", duration: 1)
        XCTAssertEqual(segments.first?.text, "원문입니다.")
        XCTAssertEqual(segments.first?.start, 0.2)
        XCTAssertEqual(segments.first?.timingQuality, "approximate")
        XCTAssertEqual(segments.first?.alignmentScore, -1)
    }
    func testChangedTextInvalidTimesAndFabricatedQualityAreRejected() throws {
        for override: [String: Any] in [["text": "추가한 문장"], ["originalText": "바뀐 원문"], ["id": 2],
            ["start": -0.1], ["start": 0.9], ["end": 1.1], ["timingQuality": "exact"]] {
            XCTAssertThrowsError(try SpeechAlignment.decode(document(override), text: "원문입니다.", duration: 1))
        }
        XCTAssertThrowsError(try SpeechAlignment.decode(document(), text: "다른 원문", duration: 1))
        XCTAssertThrowsError(try SpeechAlignment.decode(document(), text: "원문입니다.", duration: 2))
    }
    func testAlignmentFailureReusesRawWithoutStartingCodexOrEncodingAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("hub/checkpoints/model.pt")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: model)
        let wave = PCMFile.wave(Data(repeating: 1, count: 32000))
        let raw = try JSONSerialization.data(withJSONObject: ["audioHash": digest(wave), "language": "ko", "text": "원문입니다."])
        let receipt = root.appendingPathComponent("dictation.json")
        try raw.write(to: receipt)
        let script = root.appendingPathComponent("align")
        func writeScript(_ text: String) throws {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        try writeScript("#!/bin/sh\nexit 1\n")
        let config = TranscriptionConfiguration(codex: URL(fileURLWithPath: "/usr/bin/false"),
            ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), python: script, alignmentModelDirectory: root)
        let recognizer = ChatGPTSpeechRecognizer()
        do { _ = try await recognizer.transcribe(wave: wave, configuration: config, workspace: root); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: receipt), raw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("alignment.json").path))
        let fixture = root.appendingPathComponent("fixture.json"); try document().write(to: fixture)
        try writeScript("""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then cp '\(fixture.path)' "$2"; exit 0; fi
          shift
        done
        exit 1
        """)
        let result = try await recognizer.transcribe(wave: wave, configuration: config, workspace: root)
        XCTAssertEqual(result.first?.text, "원문입니다.")
        try writeScript("#!/bin/sh\nexit 1\n")
        let cached = try await recognizer.transcribe(wave: wave, configuration: config, workspace: root)
        XCTAssertEqual(cached, result, "Committed alignment must not spawn another process")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.m4a").path))
        var changed = wave; changed[changed.count - 1] = 3
        do { _ = try await recognizer.transcribe(wave: changed, configuration: config, workspace: root); XCTFail() }
        catch TranscriptionError.sourceChanged {}
    }
}
