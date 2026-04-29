import Foundation

public enum CodexRelayRole: String, Codable, Equatable, Sendable {
    case phone
    case mac
}

public struct CodexRelayRegistration: Codable, Equatable, Sendable {
    public var type: String
    public var v: Int
    public var platform: String
    public var role: CodexRelayRole
    public var capabilities: [String]
    public var room: String
    public var name: String
    public var token: String
    public var metadata: [String: JSONValue]

    public init(
        role: CodexRelayRole,
        room: String,
        name: String,
        token: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.type = "register"
        self.v = 1
        self.platform = "codex_mobile"
        self.role = role
        self.capabilities = ["raw_jsonrpc_tunnel", "ping_pong"]
        self.room = room
        self.name = name
        self.token = token
        self.metadata = metadata
    }
}

public struct CodexRelayAcknowledgement: Codable, Equatable, Sendable {
    public var type: String
    public var ok: Bool
    public var error: String?
}

public struct CodexRelayControlMessage: Codable, Equatable, Sendable {
    public var type: String
    public var ok: Bool?
    public var error: String?

    public init(type: String, ok: Bool? = nil, error: String? = nil) {
        self.type = type
        self.ok = ok
        self.error = error
    }
}

public enum CodexRelayWire {
    public static func registrationData(_ registration: CodexRelayRegistration) throws -> Data {
        try JSONEncoder().encode(registration)
    }

    public static func registrationString(_ registration: CodexRelayRegistration) throws -> String {
        let data = try registrationData(registration)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedMessage
        }
        return raw
    }

    public static func acknowledgement(from message: URLSessionWebSocketTask.Message) throws -> CodexRelayAcknowledgement {
        let data = try data(from: message)
        return try JSONDecoder().decode(CodexRelayAcknowledgement.self, from: data)
    }

    public static func control(from message: URLSessionWebSocketTask.Message) -> CodexRelayControlMessage? {
        guard let data = try? data(from: message) else { return nil }
        return try? JSONDecoder().decode(CodexRelayControlMessage.self, from: data)
    }

    public static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case let .string(value):
            Data(value.utf8)
        case let .data(value):
            value
        @unknown default:
            throw AppServerClientError.malformedMessage
        }
    }

    public static func pongMessage() throws -> URLSessionWebSocketTask.Message {
        let data = try JSONEncoder().encode(CodexRelayControlMessage(type: "pong"))
        guard let raw = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedMessage
        }
        return .string(raw)
    }
}
