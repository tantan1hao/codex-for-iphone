import XCTest
@testable import CodexMobileKit

final class JSONRPCTests: XCTestCase {
    func testEncodesInitializeRequestShape() throws {
        let message = JSONRPCMessage.request(
            id: .int(1),
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_mobile",
                    "title": "Codex Mobile",
                    "version": "0.1.0",
                ],
            ]
        )

        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["id"] as? Int, 1)
        XCTAssertEqual(object?["method"] as? String, "initialize")
        XCTAssertNotNil(object?["params"])
    }

    func testDecodesServerRequest() throws {
        let raw = #"{"id":4,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr","turnId":"turn","itemId":"item","command":"swift test"}}"#
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: Data(raw.utf8))

        XCTAssertEqual(message.id, .int(4))
        XCTAssertEqual(message.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(message.params?.objectValue?["command"]?.stringValue, "swift test")
    }
}

