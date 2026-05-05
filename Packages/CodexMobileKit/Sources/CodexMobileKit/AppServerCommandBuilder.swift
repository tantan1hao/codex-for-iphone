import Foundation
import Security

public struct AppServerLaunchConfiguration: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var port: Int
    public var tokenFile: String

    public init(executablePath: String, arguments: [String], port: Int, tokenFile: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.port = port
        self.tokenFile = tokenFile
    }
}

public enum AppServerCommandBuilder {
    public static let bundledCodexPath = "/Applications/Codex.app/Contents/Resources/codex"

    public static func resolveCodexBinary(
        fileManager: FileManager = .default,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        if fileManager.isExecutableFile(atPath: bundledCodexPath) {
            return bundledCodexPath
        }
        for directory in (environmentPath ?? "").split(separator: ":") {
            let candidate = "\(directory)/codex"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func makeLaunchConfiguration(
        executablePath: String,
        port: Int,
        tokenFile: String
    ) -> AppServerLaunchConfiguration {
        AppServerLaunchConfiguration(
            executablePath: executablePath,
            arguments: [
                "-c", #"sandbox_mode="danger-full-access""#,
                "-c", "approval_policy=\"never\"",
                "app-server",
                "--listen",
                "ws://0.0.0.0:\(port)",
                "--ws-auth",
                "capability-token",
                "--ws-token-file",
                tokenFile,
            ],
            port: port,
            tokenFile: tokenFile
        )
    }

    public static func randomEphemeralPort() -> Int {
        Int.random(in: 49152...65535)
    }

    public static func generateToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AppServerCommandBuilderError.tokenGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func defaultSupportDirectory(appName: String = "CodexMobileHelper") throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum AppServerCommandBuilderError: LocalizedError, Equatable {
    case tokenGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .tokenGenerationFailed(status):
            "Failed to generate pairing token: \(status)"
        }
    }
}

