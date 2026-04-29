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
    public var relayURL: URL?
    public var relayRoom: String?

    public init(
        name: String,
        host: String,
        port: Int,
        token: String,
        cwd: String,
        relayURL: URL? = nil,
        relayRoom: String? = nil
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoom = relayRoom?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { throw PairingPayloadError.emptyName }
        guard Self.isValidHost(trimmedHost) else { throw PairingPayloadError.invalidHost }
        guard (1...65535).contains(port) else { throw PairingPayloadError.invalidPort }
        guard trimmedToken.count >= 32 else { throw PairingPayloadError.invalidToken }
        guard trimmedCwd.hasPrefix("/") else { throw PairingPayloadError.invalidCwd }
        if relayURL != nil || trimmedRoom != nil {
            guard let relayURL, Self.isValidRelayURL(relayURL) else { throw PairingPayloadError.invalidRelayURL }
            guard let trimmedRoom, Self.isValidRelayRoom(trimmedRoom) else { throw PairingPayloadError.invalidRelayRoom }
            self.relayURL = relayURL
            self.relayRoom = trimmedRoom
        } else {
            self.relayURL = nil
            self.relayRoom = nil
        }

        self.name = trimmedName
        self.host = trimmedHost
        self.port = port
        self.token = trimmedToken
        self.cwd = trimmedCwd
    }

    public var websocketURL: URL {
        relayURL ?? localWebSocketURL
    }

    public var localWebSocketURL: URL {
        URL(string: "ws://\(host):\(port)")!
    }

    public var readyzURL: URL {
        URL(string: "http://\(host):\(port)/readyz")!
    }

    public var usesRelay: Bool {
        relayURL != nil && relayRoom != nil
    }

    public var connectionTargetDescription: String {
        if let relayURL, let relayRoom {
            "\(relayURL.host ?? relayURL.absoluteString) · \(relayRoom)"
        } else {
            "\(host):\(port)"
        }
    }

    public var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "cwd", value: cwd),
        ]
        if let relayURL, let relayRoom {
            queryItems.append(URLQueryItem(name: "mode", value: "relay"))
            queryItems.append(URLQueryItem(name: "relay", value: relayURL.absoluteString))
            queryItems.append(URLQueryItem(name: "room", value: relayRoom))
        }
        components.queryItems = queryItems
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
        let relayURL = items["relay"].flatMap(URL.init(string:))
        let relayRoom = items["room"]
        return try PairingPayload(
            name: name,
            host: host,
            port: port,
            token: token,
            cwd: cwd,
            relayURL: relayURL,
            relayRoom: relayRoom
        )
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("/") else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == ":"
        }
    }

    private static func isValidRelayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host?.isEmpty == false
        else {
            return false
        }
        return true
    }

    private static func isValidRelayRoom(_ value: String) -> Bool {
        guard value.count >= 8 else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
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
    case invalidRelayURL
    case invalidRelayRoom

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
        case .invalidRelayURL: "The relay URL must be a ws:// or wss:// URL."
        case .invalidRelayRoom: "The relay room is invalid."
        }
    }
}
