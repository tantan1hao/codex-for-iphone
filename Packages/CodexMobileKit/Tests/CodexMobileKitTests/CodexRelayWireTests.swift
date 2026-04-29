import XCTest
@testable import CodexMobileKit

final class CodexRelayWireTests: XCTestCase {
    func testEncodesRegisterFrame() throws {
        let registration = CodexRelayRegistration(
            role: .phone,
            room: "room_abcdef123456",
            name: "Codex Mobile",
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            metadata: ["adapter": "codex_mobile_ios"]
        )

        let data = try CodexRelayWire.registrationData(registration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "register")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["platform"] as? String, "codex_mobile")
        XCTAssertEqual(object["role"] as? String, "phone")
        XCTAssertEqual(object["capabilities"] as? [String], ["raw_jsonrpc_tunnel", "ping_pong"])
        XCTAssertEqual(object["room"] as? String, "room_abcdef123456")
        XCTAssertEqual(object["token"] as? String, "abcdefghijklmnopqrstuvwxyzabcdef0123456789")
    }

    func testDecodesRegisterAckAndPongControl() throws {
        let ack = try CodexRelayWire.acknowledgement(from: .string(#"{"type":"register_ack","ok":true}"#))
        XCTAssertEqual(ack.type, "register_ack")
        XCTAssertTrue(ack.ok)

        let pong = try CodexRelayWire.pongMessage()
        let control = try XCTUnwrap(CodexRelayWire.control(from: pong))
        XCTAssertEqual(control.type, "pong")
    }
}
