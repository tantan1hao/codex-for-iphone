import Foundation

@MainActor
public final class AppServerWebSocketClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var task: URLSessionWebSocketTask?
    private var nextRequestID = 1
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation

    public let events: AsyncStream<AppServerEvent>

    public init() {
        var continuation: AsyncStream<AppServerEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
        eventContinuation.finish()
    }

    public func connect(to pairing: PairingPayload, appVersion: String) async throws {
        try await checkReady(to: pairing)
        var request = URLRequest(url: pairing.websocketURL)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.task = socket
        socket.resume()
        startReceiveLoop()
        do {
            try await initialize(appVersion: appVersion)
        } catch {
            disconnect(emitEvent: false)
            throw error
        }
    }

    public func checkReady(to pairing: PairingPayload) async throws {
        var request = URLRequest(url: pairing.readyzURL)
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServerClientError.transport("Codex app-server did not return an HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            throw AppServerClientError.transport("Codex app-server readiness check returned \(httpResponse.statusCode).")
        }
    }

    public func disconnect(emitEvent: Bool = true) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: AppServerClientError.notConnected)
        }
        pendingRequests.removeAll()
        if emitEvent {
            eventContinuation.yield(.disconnected("Disconnected"))
        }
    }

    public func initialize(appVersion: String) async throws {
        let params: JSONValue = [
            "clientInfo": [
                "name": "codex_mobile",
                "title": "Codex Mobile",
                "version": .string(appVersion),
            ],
            "capabilities": [
                "experimentalApi": true,
            ],
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try await sendNotification(method: "initialized")
    }

    @discardableResult
    public func listThreads(limit: Int = 40) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/list",
            params: [
                "limit": .number(Double(limit)),
                "sortBy": "updatedAt",
                "sortDirection": "desc",
            ]
        )
    }

    @discardableResult
    public func startThread(cwd: String) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/start",
            params: [
                "cwd": .string(cwd),
                "approvalsReviewer": "user",
            ]
        )
    }

    @discardableResult
    public func resumeThread(id threadID: String) async throws -> JSONValue {
        try await sendRequest(method: "thread/resume", params: ["threadId": .string(threadID)])
    }

    @discardableResult
    public func startTurn(threadID: String, text: String) async throws -> JSONValue {
        try await sendRequest(
            method: "turn/start",
            params: [
                "threadId": .string(threadID),
                "input": [
                    [
                        "type": "text",
                        "text": .string(text),
                        "text_elements": [],
                    ],
                ],
                "approvalsReviewer": "user",
            ]
        )
    }

    @discardableResult
    public func interruptTurn(threadID: String) async throws -> JSONValue {
        try await sendRequest(method: "turn/interrupt", params: ["threadId": .string(threadID)])
    }

    public func respondToServerRequest(id: JSONRPCID, result: JSONValue) async throws {
        try await send(message: .response(id: id, result: result))
    }

    @discardableResult
    public func sendRequest(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard task != nil else { throw AppServerClientError.notConnected }
        let id = JSONRPCID.int(nextRequestID)
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task { @MainActor in
                do {
                    try await self.send(message: .request(id: id, method: method, params: params))
                } catch {
                    self.pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sendNotification(method: String, params: JSONValue? = nil) async throws {
        try await send(message: .notification(method: method, params: params))
    }

    private func send(message: JSONRPCMessage) async throws {
        guard let task else { throw AppServerClientError.notConnected }
        let data = try encoder.encode(message)
        guard let rawMessage = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedMessage
        }
        try await task.send(.string(rawMessage))
    }

    private func startReceiveLoop() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let task = self.task {
                do {
                    let message = try await task.receive()
                    try self.handle(webSocketMessage: message)
                } catch {
                    self.eventContinuation.yield(.disconnected(error.localizedDescription))
                    self.failPendingRequests(error)
                    if self.task === task {
                        self.task = nil
                    }
                    return
                }
            }
        }
    }

    private func handle(webSocketMessage: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch webSocketMessage {
        case let .string(value):
            data = Data(value.utf8)
        case let .data(value):
            data = value
        @unknown default:
            throw AppServerClientError.malformedMessage
        }

        let message = try decoder.decode(JSONRPCMessage.self, from: data)
        if let method = message.method, let id = message.id {
            eventContinuation.yield(.serverRequest(id: id, method: method, params: message.params))
            return
        }
        if let method = message.method {
            eventContinuation.yield(.notification(method: method, params: message.params))
            return
        }
        guard let id = message.id else {
            throw AppServerClientError.malformedMessage
        }
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        if let error = message.error {
            continuation.resume(throwing: AppServerClientError.requestFailed(error))
        } else {
            continuation.resume(returning: message.result ?? .null)
        }
    }

    private func failPendingRequests(_ error: Error) {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }
}
