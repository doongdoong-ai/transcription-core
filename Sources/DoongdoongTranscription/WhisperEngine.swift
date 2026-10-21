import Foundation
import Darwin

private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func install(_ value: Process) { lock.lock(); defer { lock.unlock() }; process = value }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning {
            // Only the private child owned by this engine. No useful state lives
            // in the server; completed results are committed by the session.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        process = nil
    }
    deinit { stop() }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A single resident whisper.cpp model, shared across recording sessions.
/// All inference and configuration changes pass through a FIFO gate: actor
/// isolation alone would not serialize work across an awaited HTTP request.
public actor WhisperEngine: SpeechRecognizer {
    private let child = ChildProcess()
    private var process: Process?
    private var endpoint: URL?
    private var identity: String?
    private var runtimeDirectory: URL?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let session: URLSession
    public private(set) var modelLoadCount = 0
    public var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1200
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }

    /// Suitable for application termination. Normal callers should await unload().
    public nonisolated func shutdownImmediately() { child.stop() }
    public func unload() async { await acquire(); defer { release() }; stop() }
    deinit { child.stop(); session.invalidateAndCancel(); if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) } }

    public func transcribe(wave: Data, configuration: WhisperConfiguration) async throws -> [SpeechSegment] {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        guard wave.count >= 44, wave.count <= 300 * 32000 + 1_048_576 else { throw TranscriptionError.invalidAudio }
        do {
            try await start(configuration)
            guard let endpoint else { throw TranscriptionError.server("시작하지 못했습니다.") }
            let boundary = "doongdoong-" + UUID().uuidString
            var body = Data()
            func field(_ key: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("response_format", "verbose_json")
            field("language", configuration.language)
            field("translate", "false")
            field("token_timestamps", "false")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(wave); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: endpoint.appendingPathComponent("inference"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TranscriptionError.server("전사 요청을 완료하지 못했습니다. 다시 시도해 주세요.")
            }
            guard data.count <= 8 * 1024 * 1024 else { throw TranscriptionError.invalidResponse }
            struct Response: Decodable { let segments: [SpeechSegment] }
            let repaired = Data(String(decoding: data, as: UTF8.self).utf8)
            guard let result = try? JSONDecoder().decode(Response.self, from: repaired) else { throw TranscriptionError.invalidResponse }
            return result.segments
        } catch {
            // An HTTP cancellation does not cancel native inference. Stop this
            // child before releasing the gate, so the next job cannot overlap it.
            stop()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func start(_ config: WhisperConfiguration) async throws {
        let key = try config.identity()
        if identity == key, process?.isRunning == true { return }
        stop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doongdoong-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        runtimeDirectory = root
        let port = try Self.freePort()
        let route = "/" + UUID().uuidString.lowercased()
        let endpoint = URL(string: "http://127.0.0.1:\(port)\(route)")!
        let process = Process()
        process.executableURL = config.executable
        process.arguments = ["--host", "127.0.0.1", "--port", String(port), "--request-path", route,
                             "--public", root.path, "-m", config.model.path, "-l", config.language,
                             "-t", "4", "-p", "1", "-bs", "5", "-bo", "5", "-sns", "-nlp",
                             "--vad", "-vm", config.vadModel.path, "-vspd", "100", "-vp", "200"]
        process.currentDirectoryURL = root
        // Never inherit API keys, account tokens or proxy configuration.
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); child.install(process)
        self.process = process
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw TranscriptionError.server("모델을 불러오지 못했습니다. whisper.cpp 1.9.5 이상과 모델 파일을 확인해 주세요.") }
            var request = URLRequest(url: endpoint.appendingPathComponent("health"))
            request.timeoutInterval = 1
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: String], object["status"] == "ok" {
                self.endpoint = endpoint; identity = key; modelLoadCount += 1; return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TranscriptionError.server("모델 준비 시간이 초과되었습니다.")
    }

    private func stop() {
        child.stop(); process = nil; endpoint = nil; identity = nil
        if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) }
        runtimeDirectory = nil
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TranscriptionError.server("로컬 통신을 준비하지 못했습니다.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw TranscriptionError.server("로컬 포트를 준비하지 못했습니다.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0 else { throw TranscriptionError.server("로컬 포트를 읽지 못했습니다.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
