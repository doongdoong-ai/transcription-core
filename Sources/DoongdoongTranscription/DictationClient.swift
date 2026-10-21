import Foundation

/// File dictation, separate from subsequent text correction. No public API key,
/// endpoint override, credential persistence, or third-party ASR wrapper is used.
public struct DictationCredentials: Sendable {
    let token: String
    let accountID: String

    public init(token: String) throws {
        let parts = token.split(separator: ".")
        guard parts.count == 3, !token.contains(where: \.isWhitespace) else { throw DictationError.login }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, !account.isEmpty,
              !account.contains(where: \.isWhitespace) else { throw DictationError.login }
        self.token = token; accountID = account
    }
}

public enum DictationError: LocalizedError {
    case login, rejected, tooLarge, rateLimited, unavailable, invalidResponse, empty, invalidAudio
    case http(Int), network(Int)
    public var errorDescription: String? {
        switch self {
        case .login: "ChatGPT 로그인을 확인해 주세요. API 키 로그인으로는 음성을 처리할 수 없습니다."
        case .rejected: "음성 처리 서버가 접근을 거부했습니다. 로그인 상태와 계정의 음성 기능을 확인해 주세요."
        case .tooLarge: "음성 처리 서버에 보낼 파일이 너무 큽니다. 원본 녹음은 보관되어 있습니다."
        case .rateLimited: "음성 처리 사용량 제한에 도달했습니다. 잠시 후 다시 시도해 주세요."
        case .unavailable: "음성 처리 서버에 연결하지 못했습니다. 녹음은 보관되어 있습니다."
        case .invalidResponse: "음성 처리 서버에서 올바른 전사문을 받지 못했습니다."
        case .empty: "전사문이 비어 있습니다. 음성이 없는 녹음인지 확인해 주세요."
        case .invalidAudio: "전송할 음성 파일을 확인할 수 없습니다."
        case .http(let status): "음성 처리 서버가 파일을 처리하지 못했습니다 (HTTP \(status)). 원본 녹음은 보관되어 있습니다."
        case .network(let code): "음성 파일 전송에 실패했습니다 (연결 오류 \(code)). 원본 녹음은 보관되어 있습니다."
        }
    }
}

public final class DictationClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // This is an internal product endpoint, not a supported public transcription API.
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    public static let maximumUploadBytes = 100 * 1024 * 1024

    public override init() { super.init() }

    public func transcribe(m4a: URL, language: String, credentials: DictationCredentials,
                           workspace: URL) async throws -> String {
        try Task.checkCancellation()
        let boundary = "doongdoong-\(UUID().uuidString)"
        let body = workspace.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeBody(audio: m4a, language: language, boundary: boundary, destination: body)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 1800
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 1800
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.upload(for: request, fromFile: body)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw DictationError.invalidResponse }
            return try Self.decode(data, status: response.statusCode)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? DictationError { throw error }
            // Never display remote bodies, credentials, request headers or arbitrary diagnostics.
            if let error = error as? URLError { throw DictationError.network(error.code.rawValue) }
            throw DictationError.unavailable
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func decode(_ data: Data, status: Int) throws -> String {
        switch status {
        case 200..<300: break
        case 401: throw DictationError.login
        case 403: throw DictationError.rejected
        case 413: throw DictationError.tooLarge
        case 429: throw DictationError.rateLimited
        default: throw DictationError.http(status)
        }
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw DictationError.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictationError.empty }
        return text
    }

    static func writeBody(audio: URL, language: String, boundary: String, destination: URL) throws {
        guard ["ko", "en", "ja", "auto"].contains(language),
              audio.isFileURL, destination.isFileURL,
              let values = try? audio.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw DictationError.invalidAudio }
        guard size <= maximumUploadBytes else { throw DictationError.tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw DictationError.invalidAudio }
        let output = try FileHandle(forWritingTo: destination)
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close(); try? output.close() }
        if language != "auto" {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
        }
        // Fixed filename avoids exposing a private lecture title or permitting header injection.
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        var copied = 0
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            copied += data.count
            guard copied <= maximumUploadBytes else { throw DictationError.tooLarge }
            try output.write(contentsOf: data)
        }
        guard copied == size else { throw DictationError.invalidAudio }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
