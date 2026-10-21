import Foundation
import XCTest
@testable import DoongdoongTranscription

final class EngineTests: XCTestCase, @unchecked Sendable {
    private func fake() throws -> (URL, WhisperConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server")
        // Match the public whisper-server contract, detect overlapping requests.
        let source = #"""
        #!/usr/bin/python3
        import http.server, json, sys, time, threading
        args = sys.argv
        port = int(args[args.index('--port') + 1])
        route = args[args.index('--request-path') + 1]
        lock = threading.Lock()
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def reply(self, status, value):
                data = json.dumps(value).encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_GET(self):
                self.reply(200 if self.path == route + '/health' else 404, {'status': 'ok'})
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                if not lock.acquire(False):
                    self.reply(500, {}); return
                try:
                    time.sleep(0.25)
                    self.reply(200, {'segments': [{'start': 0, 'end': 1, 'text': '강의'}]})
                finally: lock.release()
        http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (root, WhisperConfiguration(executable: script, model: script, vadModel: script))
    }

    func testConcurrentSessionsShareOneResidentProcessAndSerializeRequests() async throws {
        let (root, config) = try fake(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = WhisperEngine()
        let wave = PCMFile.wave(Data(repeating: 1, count: 32000))
        async let a = engine.transcribe(wave: wave, configuration: config)
        async let b = engine.transcribe(wave: wave, configuration: config)
        let result = try await (a, b)
        XCTAssertEqual(result.0, result.1)
        let loads = await engine.modelLoadCount; XCTAssertEqual(loads, 1)
        let pid = await engine.processIdentifier; XCTAssertNotNil(pid)
        await engine.unload()
        let after = await engine.processIdentifier; XCTAssertNil(after)
    }

    func testCancelledInferenceStopsChildAndNextRequestCanRestart() async throws {
        let (root, config) = try fake(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = WhisperEngine()
        let wave = PCMFile.wave(Data(repeating: 1, count: 32000))
        _ = try await engine.transcribe(wave: wave, configuration: config)
        let task = Task { try await engine.transcribe(wave: wave, configuration: config) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let stopped = await engine.processIdentifier; XCTAssertNil(stopped)
        let result = try await engine.transcribe(wave: wave, configuration: config)
        XCTAssertEqual(result.first?.text, "강의")
        let loads = await engine.modelLoadCount; XCTAssertEqual(loads, 2)
        await engine.unload()
    }

    /// Opt-in smoke test: two requests to the installed model, no cloud/account.
    func testInstalledEngineReusesModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["DD_WHISPER_SERVER"], let model = env["DD_WHISPER_MODEL"],
              let vad = env["DD_WHISPER_VAD"], let audio = env["DD_WHISPER_AUDIO"] else { throw XCTSkip("Set DD_WHISPER_* to run the installed-engine smoke test") }
        let config = WhisperConfiguration(executable: URL(fileURLWithPath: executable), model: URL(fileURLWithPath: model), vadModel: URL(fileURLWithPath: vad))
        let wave = try Data(contentsOf: URL(fileURLWithPath: audio))
        let engine = WhisperEngine()
        do {
            let first = try await engine.transcribe(wave: wave, configuration: config)
            let pid = await engine.processIdentifier
            let second = try await engine.transcribe(wave: wave, configuration: config)
            XCTAssertFalse(first.isEmpty); XCTAssertFalse(second.isEmpty)
            let same = await engine.processIdentifier; XCTAssertEqual(same, pid)
            let loads = await engine.modelLoadCount; XCTAssertEqual(loads, 1)
            XCTAssertTrue(first.allSatisfy { $0.start.isFinite && $0.end > $0.start })
            print("Resident Whisper smoke: loads=\(loads), pid=\(pid ?? 0), segments=\(first.count)/\(second.count)")
            await engine.unload()
        } catch { await engine.unload(); throw error }
    }
}
