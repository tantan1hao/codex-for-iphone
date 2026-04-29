import XCTest
@testable import CodexMobileKit

final class AppServerCommandBuilderTests: XCTestCase {
    func testLaunchArgumentsUseAuthenticatedWebSocket() {
        let launch = AppServerCommandBuilder.makeLaunchConfiguration(
            executablePath: "/usr/local/bin/codex",
            port: 50001,
            tokenFile: "/tmp/token"
        )

        XCTAssertEqual(launch.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(launch.arguments, [
            "app-server",
            "--listen",
            "ws://0.0.0.0:50001",
            "--ws-auth",
            "capability-token",
            "--ws-token-file",
            "/tmp/token",
        ])
    }

    func testGeneratedTokenIsHighEntropyHex() throws {
        let token = try AppServerCommandBuilder.generateToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }
}
