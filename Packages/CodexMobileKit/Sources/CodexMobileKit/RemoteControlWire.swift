import Foundation

public enum RemoteControlClientEnvelopeType: String, Codable, Equatable, Sendable {
    case clientMessage = "client_message"
    case ack
    case ping
    case clientClosed = "client_closed"
}

public enum RemoteControlServerEnvelopeType: String, Codable, Equatable, Sendable {
    case serverMessage = "server_message"
    case ack
    case pong
}

public struct RemoteControlClientEnvelope: Codable, Equatable, Sendable {
    public var type: RemoteControlClientEnvelopeType
    public var clientID: String
    public var streamID: String?
    public var seqID: Int?
    public var cursor: String?
    public var message: JSONRPCMessage?

    public init(
        type: RemoteControlClientEnvelopeType,
        clientID: String,
        streamID: String? = nil,
        seqID: Int? = nil,
        cursor: String? = nil,
        message: JSONRPCMessage? = nil
    ) {
        self.type = type
        self.clientID = clientID
        self.streamID = streamID
        self.seqID = seqID
        self.cursor = cursor
        self.message = message
    }

    public static func clientMessage(
        _ message: JSONRPCMessage,
        clientID: String,
        streamID: String,
        seqID: Int
    ) -> RemoteControlClientEnvelope {
        RemoteControlClientEnvelope(
            type: .clientMessage,
            clientID: clientID,
            streamID: streamID,
            seqID: seqID,
            message: message
        )
    }

    public static func ack(clientID: String, streamID: String?, seqID: Int) -> RemoteControlClientEnvelope {
        RemoteControlClientEnvelope(type: .ack, clientID: clientID, streamID: streamID, seqID: seqID)
    }

    public static func ping(clientID: String, streamID: String?) -> RemoteControlClientEnvelope {
        RemoteControlClientEnvelope(type: .ping, clientID: clientID, streamID: streamID)
    }

    public static func clientClosed(clientID: String, streamID: String?) -> RemoteControlClientEnvelope {
        RemoteControlClientEnvelope(type: .clientClosed, clientID: clientID, streamID: streamID)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case streamID = "stream_id"
        case seqID = "seq_id"
        case cursor
        case message
    }
}

public struct RemoteControlServerEnvelope: Codable, Equatable, Sendable {
    public var type: RemoteControlServerEnvelopeType
    public var clientID: String
    public var streamID: String?
    public var seqID: Int?
    public var status: String?
    public var message: JSONRPCMessage?

    public init(
        type: RemoteControlServerEnvelopeType,
        clientID: String,
        streamID: String? = nil,
        seqID: Int? = nil,
        status: String? = nil,
        message: JSONRPCMessage? = nil
    ) {
        self.type = type
        self.clientID = clientID
        self.streamID = streamID
        self.seqID = seqID
        self.status = status
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case streamID = "stream_id"
        case seqID = "seq_id"
        case status
        case message
    }
}

