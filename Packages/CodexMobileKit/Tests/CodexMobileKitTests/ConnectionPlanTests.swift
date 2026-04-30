import XCTest
@testable import CodexMobileKit

final class ConnectionPlanTests: XCTestCase {
    func testDirectPlanDoesNotRequireDesktopAppChanges() throws {
        let payload = try PairingPayload(
            name: "Mac",
            host: "192.168.1.20",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project"
        )

        let plan = payload.connectionPlan

        XCTAssertEqual(plan.transport, .helperLAN)
        XCTAssertTrue(plan.canRunWithoutDesktopAppChanges)
        XCTAssertFalse(plan.registersRelay)
        XCTAssertFalse(plan.usesRemoteControlEnvelope)
        XCTAssertEqual(plan.readyzURL?.absoluteString, "http://192.168.1.20:49320/readyz")
        XCTAssertEqual(plan.webSocketURL.absoluteString, "ws://192.168.1.20:49320")
        XCTAssertTrue(plan.launchesHelperSidecarAppServer)
    }

    func testRawRelayPlanDoesNotRequireDesktopAppChanges() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com/codex-mobile"))
        let payload = try PairingPayload(
            name: "Mac",
            host: "192.168.1.20",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project",
            relayURL: relayURL,
            relayRoom: "room_abcdef123456"
        )

        let plan = payload.connectionPlan

        XCTAssertEqual(plan.transport, .helperRelay)
        XCTAssertTrue(plan.canRunWithoutDesktopAppChanges)
        XCTAssertTrue(plan.registersRelay)
        XCTAssertFalse(plan.usesRemoteControlEnvelope)
        XCTAssertNil(plan.readyzURL)
        XCTAssertEqual(plan.webSocketURL, relayURL)
        XCTAssertTrue(plan.launchesHelperSidecarAppServer)
    }

    func testRemoteControlPlanDeclaresDesktopConfigurationRequirement() throws {
        let relayURL = try XCTUnwrap(URL(string: "wss://relay.example.com/codex-mobile"))
        let payload = try PairingPayload(
            name: "Mac",
            host: "remote",
            port: 443,
            token: "550e8400-e29b-41d4-a716-446655440000",
            cwd: "/",
            relayURL: relayURL,
            relayRoom: "7a2d63e5-9b60-487e-aa4d-a4741152ce19",
            connectionMode: .remoteControl
        )

        let plan = payload.connectionPlan

        XCTAssertEqual(plan.transport, .desktopRemoteControl)
        XCTAssertFalse(plan.canRunWithoutDesktopAppChanges)
        XCTAssertTrue(plan.registersRelay)
        XCTAssertTrue(plan.usesRemoteControlEnvelope)
        XCTAssertNil(plan.readyzURL)
        XCTAssertEqual(plan.webSocketURL, relayURL)
        XCTAssertFalse(plan.launchesHelperSidecarAppServer)
    }
}

