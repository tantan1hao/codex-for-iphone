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

    func testEncodesRemoteControlRegisterFrame() throws {
        let registration = CodexRelayRegistration(
            role: .phone,
            room: "7a2d63e5-9b60-487e-aa4d-a4741152ce19",
            name: "Codex Mobile",
            token: "550e8400-e29b-41d4-a716-446655440000",
            capabilities: ["remote_control_v2"],
            metadata: ["mode": "remote_control"]
        )

        let data = try CodexRelayWire.registrationData(registration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])

        XCTAssertEqual(object["capabilities"] as? [String], ["remote_control_v2"])
        XCTAssertEqual(metadata["mode"] as? String, "remote_control")
    }
}
