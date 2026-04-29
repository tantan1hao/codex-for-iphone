import Foundation

public enum JSONRPCID: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case let .string(value): value
        case let .int(value): String(value)
        }
    }
}

public struct JSONRPCError: Codable, Equatable, Sendable, Error {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCMessage: Codable, Equatable, Sendable {
    public var id: JSONRPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public static func request(id: JSONRPCID, method: String, params: JSONValue? = nil) -> JSONRPCMessage {
        JSONRPCMessage(id: id, method: method, params: params)
    }

    public static func notification(method: String, params: JSONValue? = nil) -> JSONRPCMessage {
        JSONRPCMessage(method: method, params: params)
    }

    public static func response(id: JSONRPCID, result: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(id: id, result: result)
    }
}

public enum AppServerEvent: Equatable, Sendable {
    case notification(method: String, params: JSONValue?)
    case serverRequest(id: JSONRPCID, method: String, params: JSONValue?)
    case disconnected(String)

    /// Best-effort extraction of the thread ID carried by an event so the
    /// client can filter out stale events from a previously-selected thread.
    public var threadID: String? {
        switch self {
        case let .notification(_, params):
            return params?.objectValue?["threadId"]?.stringValue
                ?? params?.objectValue?["thread"]?.objectValue?["id"]?.stringValue
        case let .serverRequest(_, _, params):
            return params?.objectValue?["threadId"]?.stringValue
        case .disconnected:
            return nil
        }
    }
}

public enum AppServerClientError: LocalizedError, Sendable {
    case invalidURL(String)
    case notConnected
    case malformedMessage
    case requestFailed(JSONRPCError)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            "Invalid websocket URL: \(value)"
        case .notConnected:
            "Not connected to Codex app-server."
        case .malformedMessage:
            "Codex app-server returned a malformed message."
        case let .requestFailed(error):
            error.message
        case let .transport(message):
            message
        }
    }
}
