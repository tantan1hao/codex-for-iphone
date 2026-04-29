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

    func testExtractsThreadIDFromEvents() {
        let notification = AppServerEvent.notification(method: "item/started", params: ["threadId": "thr_1"])
        let nestedNotification = AppServerEvent.notification(method: "thread/updated", params: ["thread": ["id": "thr_2"]])
        let request = AppServerEvent.serverRequest(id: .int(4), method: "item/tool/requestUserInput", params: ["threadId": "thr_3"])

        XCTAssertEqual(notification.threadID, "thr_1")
        XCTAssertEqual(nestedNotification.threadID, "thr_2")
        XCTAssertEqual(request.threadID, "thr_3")
    }
}
