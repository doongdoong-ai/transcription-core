import Foundation
import Darwin

/// A bounded JSON-RPC connection. Codex owns authentication; no credential files or RPC payloads are logged.
@MainActor
final class DictationAccountClient: NSObject {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onFailure: ((Error) -> Void)?
    override init() { super.init() }

    var isRunning: Bool { transport?.isRunning == true }

    private static let maximumMessageBytes = 4 * 1024 * 1024
    private var transport: CodexPipeTransport?
    private var generation = UUID()
    private var nextID = 0
    private var pending: [Int: PendingRequest] = [:]

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
    }

    /// Launch a JSON-RPC helper without sending Codex-specific initialization.
    func launch(executable: URL, arguments: [String], workingDirectory: URL) throws {
        guard transport == nil else { throw ClientError.message("이미 Codex 연결이 실행 중입니다.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ClientError.message("실행 파일을 찾을 수 없습니다. 설정에서 경로를 확인해 주세요.")
        }

        let token = UUID()
        generation = token
        nextID = 0
        let connection = CodexPipeTransport()
        transport = connection
        do {
            try connection.launch(executable: executable, arguments: arguments, directory: workingDirectory)
        } catch {
            transport = nil
            connection.stop()
            throw ClientError.message("AI 연결 프로그램을 시작하지 못했습니다.")
        }
        connection.read(maximumMessageBytes: Self.maximumMessageBytes) { [weak self] result in
            await self?.receive(result, generation: token)
        }
    }

    /// Start the installed Codex CLI for account checks; it owns authentication.
    func start(executable: URL, workingDirectory: URL) async throws {
        try Task.checkCancellation()
        // app-server 0.160 does not support exec's --ignore-user-config switch.
        // Keep Codex's existing login while disabling executable hooks and agent tools.
        let overrides = [
            "web_search=\"disabled\"",
            "features.hooks=false",
            "features.plugin_hooks=false",
            "features.plugins=false",
            "features.apps=false",
            "features.shell_tool=false",
            "features.multi_agent=false", "features.multi_agent_v2=false",
            "features.code_mode=false", "features.unified_exec=false",
            "features.memories=false", "features.view_image=false",
            "features.image_generation=false", "features.in_app_browser=false",
            "features.skill_search=false", "features.skip_host_skill_discovery=true",
            "skills.include_instructions=false", "skills.bundled.enabled=false",
            "project_doc_max_bytes=0", "mcp_servers={}"
        ]
        let arguments = ["app-server", "--stdio"] + overrides.flatMap { ["-c", $0] }
        try launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        do {
            _ = try await request(method: "initialize", params: [
                "clientInfo": ["name": "doongdoong-transcription", "title": "Doongdoong Transcription", "version": "1.0"],
                "capabilities": [
                    "experimentalApi": false,
                    "requestAttestation": false,
                    "explicitGatewayOauth": true
                ]
            ])
            try notify(method: "initialized")
        } catch {
            stop()
            throw error
        }
    }

    /// Requests may overlap; IDs associate each response with its own continuation.
    /// Cancelling or timing out any request closes this operation's connection.
    func request(method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let transport, transport.isRunning else { throw ClientError.disconnected }
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
            throw ClientError.message("올바른 처리 제한 시간이 필요합니다.")
        }
        guard nextID < Int.max else { throw ClientError.disconnected }
        nextID += 1
        let id = nextID
        let token = generation
        let data = try encoded(["id": id, "method": method, "params": params])

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.generation == token, self.pending[id] != nil else { return }
                    self.fail(ClientError.timedOut)
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: deadline)
                transport.write(data) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.fail(error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.pending[id] != nil else { return }
                self.fail(CancellationError())
            }
        }
    }

    /// Writes are serialized with requests, including the initialized notification.
    func notify(method: String, params: [String: Any]? = nil) throws {
        guard let transport, transport.isRunning else { throw ClientError.disconnected }
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        let data = try encoded(message)
        let token = generation
        transport.write(data) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    /// Idempotent cancellation.
    func stop() {
        close(with: CancellationError())
    }

    deinit { transport?.stop() }

    private func encoded(_ message: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(message) else { throw ClientError.invalidMessage }
        var data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= Self.maximumMessageBytes else { throw ClientError.messageTooLarge }
        data.append(0x0A)
        return data
    }

    private func receive(_ result: Result<Data, Error>, generation token: UUID) {
        guard generation == token, transport != nil else { return }
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let line):
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ClientError.invalidMessage
                }
                try receive(message)
            } catch { fail(error as? ClientError ?? ClientError.invalidMessage) }
        }
    }

    private func receive(_ message: [String: Any]) throws {
        if let method = message["method"] as? String {
            if let id = message["id"], !(id is NSNull) {
                // Reject every other tool, approval, authentication or credential request.
                let denial: [String: Any] = [
                    "id": id,
                    "error": ["code": -32601, "message": "This client only reads account metadata."]
                ]
                let connection = transport
                let data = try encoded(denial)
                connection?.write(data) { _ in connection?.stop() }
                fail(ClientError.unexpectedAction, stopTransport: false)
                // A child that does not read the denial must still be terminated.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { connection?.stop() }
                return
            }
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "turn/started" { throw ClientError.unexpectedAction }
            if method == "item/started" || method == "item/completed" {
                let kind = (params["item"] as? [String: Any])?["type"] as? String
                let allowed = ["userMessage", "agentMessage", "reasoning"]
                if let kind, !allowed.contains(kind) {
                    throw ClientError.unexpectedAction
                }
            }
            onNotification?(method, params)
            if method == "error" || method == "thread/realtime/error" {
                let details = params["error"] as? [String: Any] ?? params
                throw Self.serverError(details)
            }
            return
        }

        guard let number = message["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { throw ClientError.invalidMessage }
        guard let request = pending.removeValue(forKey: number.intValue) else { return }
        request.timeout.cancel()
        if let error = message["error"] as? [String: Any] {
            request.continuation.resume(throwing: Self.serverError(error))
        } else if let result = message["result"] as? [String: Any] {
            request.continuation.resume(returning: result)
        } else {
            request.continuation.resume(throwing: ClientError.invalidMessage)
            throw ClientError.invalidMessage
        }
    }

    private static func serverError(_ error: [String: Any]) -> Error {
        guard var message = error["message"] as? String, !message.isEmpty else {
            return ClientError.message("Codex에서 AI 연결를 완료하지 못했습니다.")
        }
        // Remote diagnostics may contain request details. Never surface bearer tokens or keys.
        for pattern in ["(?i)Bearer\\s+[^\\s\\\"']+", "\\bsk-[A-Za-z0-9_-]+", "\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"] {
            message = message.replacingOccurrences(of: pattern, with: "[비공개]", options: .regularExpression)
        }
        return ClientError.message(String(message.prefix(800)))
    }

    private func fail(_ error: Error, stopTransport: Bool = true) {
        guard transport != nil else { return }
        close(with: error, stopTransport: stopTransport)
        onFailure?(error)
    }

    private func close(with error: Error, stopTransport: Bool = true) {
        generation = UUID()
        let connection = transport
        transport = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        if stopTransport { connection?.stop() }
    }
}

private enum ClientError: LocalizedError {
    case disconnected, timedOut, invalidMessage, messageTooLarge, unexpectedAction
    case message(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "AI 연결 연결이 종료되었습니다. 다시 시도해 주세요."
        case .timedOut: return "AI 연결 연결의 응답 시간이 초과되었습니다."
        case .invalidMessage: return "AI 연결 프로그램에서 올바르지 않은 응답을 받았습니다."
        case .messageTooLarge: return "AI 연결 응답이 허용된 크기를 초과했습니다."
        case .unexpectedAction: return "계정 조회 이외의 작업이 요청되어 AI 연결를 중단했습니다."
        case .message(let message): return message
        }
    }
}

/// Owns the process and pipes independently of the main actor, including deinitialization.
private final class CodexPipeTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "app.bungbungi.rpc.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false
    private var reader: Task<Void, Never>?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && process.isRunning
    }

    func launch(executable: URL, arguments: [String], directory: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        environment.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "CODEX_API_KEY", "AZURE_OPENAI_API_KEY", "ANTHROPIC_API_KEY"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        // Only the child owns these ends after spawn; closing them makes EOF reliable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func read(maximumMessageBytes: Int, receive: @escaping @Sendable (Result<Data, Error>) async -> Void) {
        let handle = output.fileHandleForReading
        reader = Task.detached(priority: .userInitiated) {
            defer { try? handle.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            do {
                while !Task.isCancelled {
                    // POSIX read returns available bytes immediately. FileHandle's read(upToCount:)
                    // can wait to fill its requested length, deadlocking a short RPC response.
                    let count = chunk.withUnsafeMutableBytes { bytes in
                        Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw ClientError.disconnected
                    }
                    guard count > 0 else {
                        if !Task.isCancelled { await receive(.failure(ClientError.disconnected)) }
                        return
                    }
                    let data = Data(chunk.prefix(count))
                    var start = data.startIndex
                    // Scan each byte once, including oversized lines with no newline.
                    while let newline = data[start...].firstIndex(of: 0x0A) {
                        guard buffer.count + data.distance(from: start, to: newline) <= maximumMessageBytes else {
                            throw ClientError.messageTooLarge
                        }
                        buffer.append(data[start..<newline])
                        if !buffer.isEmpty { await receive(.success(buffer)) }
                        buffer.removeAll(keepingCapacity: true)
                        start = data.index(after: newline)
                        if Task.isCancelled { return }
                    }
                    guard buffer.count + data.distance(from: start, to: data.endIndex) <= maximumMessageBytes else {
                        throw ClientError.messageTooLarge
                    }
                    buffer.append(data[start...])
                }
            } catch {
                if !Task.isCancelled {
                    await receive(.failure(error as? ClientError ?? ClientError.invalidMessage))
                }
            }
        }
    }

    func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        writer.async { [self] in
            guard isRunning else { completion(ClientError.disconnected); return }
            do { try input.fileHandleForWriting.write(contentsOf: data); completion(nil) }
            catch { completion(ClientError.disconnected) }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let running = process.isRunning
        let pid = running ? process.processIdentifier : 0
        let ownsGroup = pid > 0 && getpgid(pid) == pid
        lock.unlock()
        reader?.cancel()
        if running {
            if ownsGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            let process = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if ownsGroup {
                    if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                } else if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        // Let an in-flight write finish after child termination before closing its handle.
        writer.async { [input] in try? input.fileHandleForWriting.close() }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        if reader == nil { try? output.fileHandleForReading.close() }
    }

    deinit { stop() }
}
