import XCTest
@testable import DoongdoongTranscription

final class DictationTests: XCTestCase {
    func testResponseNeverTreatsMissingOrEmptyTextAsSuccess() throws {
        XCTAssertEqual(try DictationClient.decode(Data("{\"text\":\"원문 그대로\"}".utf8), status: 200), "원문 그대로")
        for value in ["{}", "{\"text\":null}", "{\"text\":\"  \"}", "not JSON"] {
            XCTAssertThrowsError(try DictationClient.decode(Data(value.utf8), status: 200))
        }
        for status in [302, 401, 403, 413, 429, 500] {
            XCTAssertThrowsError(try DictationClient.decode(Data("secret remote diagnostic".utf8), status: status)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testMultipartUsesFixedFilenameAndOmitsAutoLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("private-lecture.m4a"), output = root.appendingPathComponent("body")
        try Data([0, 1, 2, 255]).write(to: audio)
        try DictationClient.writeBody(audio: audio, language: "auto", boundary: "test", destination: output)
        let bytes = try Data(contentsOf: output)
        let body = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"recording.m4a\""))
        XCTAssertFalse(body.contains("private-lecture"))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertNotNil(bytes.range(of: Data([0, 1, 2, 255])))
        XCTAssertTrue(body.hasSuffix("\r\n--test--\r\n"))
        XCTAssertThrowsError(try DictationClient.writeBody(audio: audio, language: "ko\r\nInjected", boundary: "test", destination: output))
    }

    func testCredentialParserRejectsAPIKeysAndMissingAccount() throws {
        XCTAssertThrowsError(try DictationCredentials(token: "sk-test"))
        XCTAssertThrowsError(try DictationCredentials(token: "header.e30.signature"))
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "test-account"]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let parsed = try DictationCredentials(token: "header.\(payload).signature")
        XCTAssertEqual(parsed.accountID, "test-account")
    }
}
