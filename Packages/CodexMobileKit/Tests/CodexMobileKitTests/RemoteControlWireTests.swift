import XCTest
@testable import CodexMobileKit

final class RemoteControlWireTests: XCTestCase {
    func testEncodesClientMessageEnvelope() throws {
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
        let envelope = RemoteControlClientEnvelope.clientMessage(
            message,
            clientID: "client-1",
            streamID: "stream-1",
            seqID: 42
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = try XCTUnwrap(object["message"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "client_message")
        XCTAssertEqual(object["client_id"] as? String, "client-1")
        XCTAssertEqual(object["stream_id"] as? String, "stream-1")
        XCTAssertEqual(object["seq_id"] as? Int, 42)
        XCTAssertEqual(nested["method"] as? String, "initialize")
    }

    func testEncodesAckEnvelope() throws {
        let envelope = RemoteControlClientEnvelope.ack(clientID: "client-1", streamID: "stream-1", seqID: 7)
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "ack")
        XCTAssertEqual(object["client_id"] as? String, "client-1")
        XCTAssertEqual(object["stream_id"] as? String, "stream-1")
        XCTAssertEqual(object["seq_id"] as? Int, 7)
        XCTAssertNil(object["message"])
    }

    func testDecodesServerMessageEnvelope() throws {
        let raw = """
        {
          "type": "server_message",
          "client_id": "client-1",
          "stream_id": "stream-1",
          "seq_id": 3,
          "message": {
            "id": 1,
            "result": {
              "ok": true
            }
          }
        }
        """

        let envelope = try JSONDecoder().decode(RemoteControlServerEnvelope.self, from: Data(raw.utf8))

        XCTAssertEqual(envelope.type, .serverMessage)
        XCTAssertEqual(envelope.clientID, "client-1")
        XCTAssertEqual(envelope.streamID, "stream-1")
        XCTAssertEqual(envelope.seqID, 3)
        XCTAssertEqual(envelope.message?.id, .int(1))
        XCTAssertEqual(envelope.message?.result?.objectValue?["ok"], .bool(true))
    }
}

