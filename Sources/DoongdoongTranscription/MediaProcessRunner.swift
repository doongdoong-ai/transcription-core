import Foundation

/// File-backed output avoids pipe deadlocks even for hour-long transcription jobs.
final class MediaProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var active = false
    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if let current, current.isRunning {
            let pid = current.processIdentifier
            // Foundation starts Process in its own group on macOS. Terminate the group so
            // CLI wrappers (e.g. npm's Codex launcher) cannot leave workers behind.
            let ownsGroup = getpgid(pid) == pid
            if ownsGroup { kill(-pid, SIGTERM) } else { current.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if ownsGroup {
                    if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                } else if current.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    public func run(executable: URL, arguments: [String], directory: URL, log: URL, input: String? = nil, timeout: Double = 7200,
                    environmentOverrides: [String: String] = [:], removingEnvironmentKeys: [String] = []) async throws {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw TranscriptionError.server("올바른 처리 제한 시간이 필요합니다.") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process()
                    do {
                        self.lock.lock()
                        let alreadyCancelled = self.cancelled
                        let alreadyActive = self.active
                        if !alreadyCancelled && !alreadyActive { self.active = true }
                        self.lock.unlock()
                        if alreadyCancelled { throw CancellationError() }
                        if alreadyActive { throw TranscriptionError.server("이미 실행 중인 작업이 있습니다.") }
                        defer { self.lock.lock(); self.process = nil; self.active = false; self.lock.unlock() }
                        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
                            throw TranscriptionError.server("처리 로그를 저장하지 못했습니다. 저장 공간과 폴더 권한을 확인해 주세요.")
                        }
                        let handle = try FileHandle(forWritingTo: log)
                        var inputHandle: FileHandle?
                        var inputURL: URL?
                        defer {
                            try? handle.close(); try? inputHandle?.close()
                            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
                        }
                        if let input {
                            let path = directory.appendingPathComponent(".stdin-\(UUID().uuidString)")
                            try Data(input.utf8).write(to: path, options: .atomic)
                            inputURL = path; inputHandle = try FileHandle(forReadingFrom: path)
                        }
                        task.executableURL = executable; task.arguments = arguments; task.currentDirectoryURL = directory
                        var env = ProcessInfo.processInfo.environment
                        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                        env.removeValue(forKey: "CODEX_THREAD_ID")
                        env.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
                        for key in removingEnvironmentKeys { env.removeValue(forKey: key) }
                        for (key, value) in environmentOverrides { env[key] = value }
                        task.environment = env
                        task.standardOutput = handle; task.standardError = handle
                        task.standardInput = inputHandle ?? FileHandle.nullDevice
                        self.lock.lock()
                        if self.cancelled { self.lock.unlock(); throw CancellationError() }
                        do { try task.run(); self.process = task; self.lock.unlock() }
                        catch { self.lock.unlock(); throw error }
                        let deadline = ProcessInfo.processInfo.systemUptime + timeout
                        var timedOut = false
                        while task.isRunning {
                            if ProcessInfo.processInfo.systemUptime > deadline { timedOut = true; self.cancel(); break }
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        task.waitUntilExit()
                        if timedOut { throw TranscriptionError.server("처리 시간이 초과되었습니다. 오디오는 보관되어 있습니다.") }
                        self.lock.lock(); let wasCancelled = self.cancelled; self.lock.unlock()
                        if wasCancelled { throw CancellationError() }
                        guard task.terminationStatus == 0 else {
                            throw TranscriptionError.server("\(executable.lastPathComponent) 실행 실패 (\(task.terminationStatus))")
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private static func tail(of log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }
}
