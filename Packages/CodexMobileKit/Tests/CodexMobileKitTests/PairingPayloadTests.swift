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
    }

    func testRejectsInvalidTokenAndRelativeCwd() {
        XCTAssertThrowsError(try PairingPayload(name: "Mac", host: "192.168.1.20", port: 49320, token: "short", cwd: "/tmp"))
        XCTAssertThrowsError(try PairingPayload(name: "Mac", host: "192.168.1.20", port: 49320, token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789", cwd: "tmp"))
    }
}
