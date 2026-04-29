import Foundation

public struct PairingPayload: Equatable, Sendable, Codable {
    public static let scheme = "codex-mobile"
    public static let host = "pair"
    public static let version = "1"

    public var name: String
    public var host: String
    public var port: Int
    public var token: String
    public var cwd: String

    public init(name: String, host: String, port: Int, token: String, cwd: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { throw PairingPayloadError.emptyName }
        guard Self.isValidHost(trimmedHost) else { throw PairingPayloadError.invalidHost }
        guard (1...65535).contains(port) else { throw PairingPayloadError.invalidPort }
        guard trimmedToken.count >= 32 else { throw PairingPayloadError.invalidToken }
        guard trimmedCwd.hasPrefix("/") else { throw PairingPayloadError.invalidCwd }

        self.name = trimmedName
        self.host = trimmedHost
        self.port = port
        self.token = trimmedToken
        self.cwd = trimmedCwd
    }

    public var websocketURL: URL {
        URL(string: "ws://\(host):\(port)")!
    }

    public var readyzURL: URL {
        URL(string: "http://\(host):\(port)/readyz")!
    }

    public var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "cwd", value: cwd),
        ]
        return components.url!
    }

    public static func parse(_ rawValue: String) throws -> PairingPayload {
        guard let url = URL(string: rawValue) else {
            throw PairingPayloadError.invalidURL
        }
        return try parse(url)
    }

    public static func parse(_ url: URL) throws -> PairingPayload {
        guard url.scheme == scheme, url.host == host else {
            throw PairingPayloadError.invalidURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingPayloadError.invalidURL
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard items["v"] == version else { throw PairingPayloadError.unsupportedVersion }
        guard let name = items["name"],
              let host = items["host"],
              let portValue = items["port"],
              let port = Int(portValue),
              let token = items["token"],
              let cwd = items["cwd"]
        else {
            throw PairingPayloadError.missingField
        }
        return try PairingPayload(name: name, host: host, port: port, token: token, cwd: cwd)
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("/") else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == ":"
        }
    }
}

public enum PairingPayloadError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedVersion
    case missingField
    case emptyName
    case invalidHost
    case invalidPort
    case invalidToken
    case invalidCwd

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The pairing URL is not a Codex Mobile pairing link."
        case .unsupportedVersion: "This pairing link uses an unsupported version."
        case .missingField: "The pairing link is missing required connection fields."
        case .emptyName: "The computer name is empty."
        case .invalidHost: "The computer host is invalid."
        case .invalidPort: "The app-server port is invalid."
        case .invalidToken: "The pairing token is too short."
        case .invalidCwd: "The workspace path must be absolute."
        }
    }
}
