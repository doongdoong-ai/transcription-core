import XCTest
@testable import DoongdoongTranscription

final class AccountClientTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("rpc.py")
        try """
        import sys,json
        for line in sys.stdin:
            m=json.loads(line)
            with open('methods.jsonl','a') as f: f.write(json.dumps(m.get('method'))+'\\n')
            if m.get('method') == 'stall': continue
            if 'id' in m:
                print(json.dumps({'id':m['id'],'result':{}}),flush=True)
            if m.get('method') == 'probe':
                print(json.dumps({'id':999,'method':'item/tool/call','params':{'tool':'shell'}}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("codex")
        try "#!/bin/sh\nexec /usr/bin/python3 -u '\(script.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }
    @MainActor func testInitializationAndAccountRequestsNeverStartAModelTurn() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DictationAccountClient(); defer { client.stop() }
        try await client.start(executable: executable, workingDirectory: root)
        _ = try await client.request(method: "account/read", params: ["refreshToken": false])
        _ = try await client.request(method: "getAuthStatus", params: ["includeToken": true])
        let lines = try String(contentsOf: root.appendingPathComponent("methods.jsonl"), encoding: .utf8)
        XCTAssertEqual(lines.split(separator: "\n"), ["\"initialize\"", "\"initialized\"", "\"account/read\"", "\"getAuthStatus\""])
    }
    @MainActor func testUnexpectedServerToolIsRefused() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DictationAccountClient(); defer { client.stop() }
        let refused = expectation(description: "tool refused")
        client.onFailure = { _ in refused.fulfill() }
        try await client.start(executable: executable, workingDirectory: root)
        _ = try await client.request(method: "probe", params: [:])
        await fulfillment(of: [refused], timeout: 3)
        XCTAssertFalse(client.isRunning)
    }
    @MainActor func testDeadlineStopsUnresponsiveAccountProcess() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DictationAccountClient(); defer { client.stop() }
        try await client.start(executable: executable, workingDirectory: root)
        do { _ = try await client.request(method: "stall", params: [:], timeout: 0.1); XCTFail() } catch {}
        XCTAssertFalse(client.isRunning)
    }
}
