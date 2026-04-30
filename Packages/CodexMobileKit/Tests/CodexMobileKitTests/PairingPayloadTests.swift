import XCTest
@testable import CodexMobileKit

final class PairingPayloadTests: XCTestCase {
    func testRoundTripDeepLink() throws {
        let payload = try PairingPayload(
            name: "MacBook Pro",
            host: "192.168.1.20",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project"
        )

        let parsed = try PairingPayload.parse(payload.deepLinkURL)

        XCTAssertEqual(parsed, payload)
        XCTAssertEqual(parsed.websocketURL.absoluteString, "ws://192.168.1.20:49320")
        XCTAssertEqual(parsed.readyzURL.absoluteString, "http://192.168.1.20:49320/readyz")
        XCTAssertFalse(parsed.usesRelay)
    }

    func testRoundTripRelayDeepLink() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com/codex-mobile"))
        let payload = try PairingPayload(
            name: "MacBook Pro",
            host: "192.168.1.20",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project",
            relayURL: relayURL,
            relayRoom: "room_abcdef123456"
        )

        let parsed = try PairingPayload.parse(payload.deepLinkURL)

        XCTAssertEqual(parsed, payload)
        XCTAssertTrue(parsed.usesRelay)
        XCTAssertTrue(parsed.usesRawRelay)
        XCTAssertFalse(parsed.usesRemoteControl)
        XCTAssertEqual(parsed.websocketURL, relayURL)
        XCTAssertEqual(parsed.localWebSocketURL.absoluteString, "ws://192.168.1.20:49320")
    }

    func testRoundTripRemoteControlDeepLink() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com/codex-mobile"))
        let payload = try PairingPayload(
            name: "Desktop Codex",
            host: "remote",
            port: 443,
            token: "550e8400-e29b-41d4-a716-446655440000",
            cwd: "/",
            relayURL: relayURL,
            relayRoom: "7a2d63e5-9b60-487e-aa4d-a4741152ce19",
            connectionMode: .remoteControl
        )

        let parsed = try PairingPayload.parse(payload.deepLinkURL)

        XCTAssertEqual(parsed, payload)
        XCTAssertTrue(parsed.usesRelay)
        XCTAssertFalse(parsed.usesRawRelay)
        XCTAssertTrue(parsed.usesRemoteControl)
        XCTAssertEqual(parsed.connectionMode, .remoteControl)
        XCTAssertEqual(parsed.websocketURL, relayURL)
        XCTAssertTrue(parsed.connectionTargetDescription.contains("Remote Control"))
    }

    func testRejectsInvalidTokenAndRelativeCwd() {
        XCTAssertThrowsError(try PairingPayload(name: "Mac", host: "192.168.1.20", port: 49320, token: "short", cwd: "/tmp"))
        XCTAssertThrowsError(try PairingPayload(name: "Mac", host: "192.168.1.20", port: 49320, token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789", cwd: "tmp"))
        XCTAssertThrowsError(try PairingPayload(
            name: "Mac",
            host: "192.168.1.20",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/tmp",
            relayURL: URL(string: "https://relay.example.com"),
            relayRoom: "room_abcdef123456"
        ))
    }
}
