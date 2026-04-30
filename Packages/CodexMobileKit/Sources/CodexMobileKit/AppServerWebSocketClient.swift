import Foundation

@MainActor
public final class AppServerWebSocketClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var task: URLSessionWebSocketTask?
    private var connectionGeneration = 0
    private var nextRequestID = 1
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private var connectionMode: PairingConnectionMode = .direct
    private var remoteControlClientID = ""
    private var remoteControlStreamID = ""
    private var remoteControlNextSeqID = 1
    private var suppressDisconnectEvents = false

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
        connectionGeneration += 1
        let generation = connectionGeneration
        let plan = pairing.connectionPlan
        if let readyzURL = plan.readyzURL {
            try await checkReady(url: readyzURL)
        }
        try ensureConnectionIsCurrent(generation)
        connectionMode = pairing.connectionMode
        if plan.usesRemoteControlEnvelope {
            remoteControlClientID = "codex-mobile-\(UUID().uuidString)"
            remoteControlStreamID = UUID().uuidString
            remoteControlNextSeqID = 1
        } else {
            remoteControlClientID = ""
            remoteControlStreamID = ""
            remoteControlNextSeqID = 1
        }
        var request = URLRequest(url: plan.webSocketURL)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        try await establishConnection(
            request: request,
            pairing: pairing,
            plan: plan,
            generation: generation,
            appVersion: appVersion
        )
    }

    private func establishConnection(
        request: URLRequest,
        pairing: PairingPayload,
        plan: CodexConnectionPlan,
        generation: Int,
        appVersion: String
    ) async throws {
        let maximumAttempts = plan.registersRelay ? 4 : 1
        var lastError: Error?
        suppressDisconnectEvents = true
        defer { suppressDisconnectEvents = false }

        for attempt in 0..<maximumAttempts {
            do {
                try await openWebSocket(request: request, pairing: pairing, plan: plan, generation: generation)
                startReceiveLoop()
                try await initialize(appVersion: appVersion)
                try ensureConnectionIsCurrent(generation)
                return
            } catch {
                closeCurrentTaskAfterFailedConnection(error)
                guard isTransientSocketNotConnected(error), attempt + 1 < maximumAttempts else {
                    throw error
                }
                lastError = error
                try await Task.sleep(nanoseconds: retryDelay(forAttempt: attempt))
            }
        }

        throw lastError ?? AppServerClientError.notConnected
    }

    private func openWebSocket(
        request: URLRequest,
        pairing: PairingPayload,
        plan: CodexConnectionPlan,
        generation: Int
    ) async throws {
        try ensureConnectionIsCurrent(generation)
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()

        if plan.registersRelay {
            try await registerRelay(pairing: pairing)
            try ensureConnectionIsCurrent(generation)
        }
    }

    private func closeCurrentTaskAfterFailedConnection(_ error: Error) {
        let socket = task
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        failPendingRequests(error)
    }

    private func ensureConnectionIsCurrent(_ generation: Int) throws {
        guard connectionGeneration == generation else {
            throw CancellationError()
        }
    }

    private func registerRelay(pairing: PairingPayload) async throws {
        guard let socket = task,
              let room = pairing.relayRoom
        else {
            throw AppServerClientError.transport("Relay pairing is missing its room.")
        }
        let registration = CodexRelayRegistration(
            role: .phone,
            room: room,
            name: "Codex Mobile",
            token: pairing.token,
            capabilities: pairing.usesRemoteControl ? ["remote_control_v2"] : nil,
            metadata: [
                "adapter": "codex_mobile_ios",
                "mode": .string(pairing.usesRemoteControl ? "remote_control" : "raw_jsonrpc"),
                "cwd": .string(pairing.cwd),
            ]
        )
        try await sendWebSocketMessage(.string(CodexRelayWire.registrationString(registration)), on: socket)
        let acknowledgement = try CodexRelayWire.acknowledgement(from: try await socket.receive())
        guard acknowledgement.type == "register_ack", acknowledgement.ok else {
            throw AppServerClientError.transport(acknowledgement.error ?? "Relay registration was rejected.")
        }
    }

    public func checkReady(to pairing: PairingPayload) async throws {
        try await checkReady(url: pairing.readyzURL)
    }

    public func checkReady(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServerClientError.transport("Codex app-server did not return an HTTP response.")
        }
        guard httpResponse.statusCode == 200 else {
            throw AppServerClientError.transport("Codex app-server readiness check returned \(httpResponse.statusCode).")
        }
    }

    public func disconnect(emitEvent: Bool = true) {
        connectionGeneration += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionMode = .direct
        remoteControlClientID = ""
        remoteControlStreamID = ""
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
    public func startThread(cwd: String, settings: CodexSessionSettings) async throws -> JSONValue {
        try await sendRequest(method: "thread/start", params: Self.threadStartParams(cwd: cwd, settings: settings))
    }

    @discardableResult
    public func resumeThread(id threadID: String) async throws -> JSONValue {
        try await sendRequest(method: "thread/resume", params: Self.resumeThreadParams(id: threadID))
    }

    @discardableResult
    public func listThreadTurns(
        threadID: String,
        limit: Int = 20,
        cursor: String? = nil,
        sortDirection: String = "desc"
    ) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/turns/list",
            params: Self.threadTurnsListParams(
                threadID: threadID,
                limit: limit,
                cursor: cursor,
                sortDirection: sortDirection
            )
        )
    }

    @discardableResult
    public func startTurn(threadID: String, text: String, cwd: String, settings: CodexSessionSettings) async throws -> JSONValue {
        try await sendRequest(method: "turn/start", params: Self.turnStartParams(threadID: threadID, text: text, cwd: cwd, settings: settings))
    }

    @discardableResult
    public func interruptTurn(threadID: String, turnID: String? = nil) async throws -> JSONValue {
        try await sendRequest(method: "turn/interrupt", params: Self.interruptTurnParams(threadID: threadID, turnID: turnID))
    }

    public func respondToServerRequest(id: JSONRPCID, result: JSONValue) async throws {
        try await send(message: .response(id: id, result: result))
    }

    @discardableResult
    public func readConfig(cwd: String?) async throws -> JSONValue {
        var params: [String: JSONValue] = ["includeLayers": true]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        return try await sendRequest(method: "config/read", params: .object(params))
    }

    @discardableResult
    public func listModels(limit: Int = 80, includeHidden: Bool = false) async throws -> JSONValue {
        try await sendRequest(
            method: "model/list",
            params: [
                "limit": .number(Double(limit)),
                "includeHidden": .bool(includeHidden),
            ]
        )
    }

    @discardableResult
    public func writeConfigValue(keyPath: String, value: JSONValue) async throws -> JSONValue {
        try await writeConfigValues([(keyPath, value)])
    }

    @discardableResult
    public func writeConfigValues(_ edits: [(String, JSONValue)]) async throws -> JSONValue {
        try await sendRequest(
            method: "config/batchWrite",
            params: [
                "edits": .array(edits.map { edit in
                    [
                        "keyPath": .string(edit.0),
                        "value": edit.1,
                        "mergeStrategy": "replace",
                    ]
                }),
                "reloadUserConfig": true,
            ]
        )
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
                    if let pending = self.pendingRequests.removeValue(forKey: id) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func sendNotification(method: String, params: JSONValue? = nil) async throws {
        try await send(message: .notification(method: method, params: params))
    }

    private func send(message: JSONRPCMessage) async throws {
        guard let task else { throw AppServerClientError.notConnected }
        let data: Data
        if connectionMode == .remoteControl {
            guard !remoteControlClientID.isEmpty, !remoteControlStreamID.isEmpty else {
                throw AppServerClientError.transport("Remote control session is not initialized.")
            }
            let seqID = remoteControlNextSeqID
            remoteControlNextSeqID += 1
            let envelope = RemoteControlClientEnvelope.clientMessage(
                message,
                clientID: remoteControlClientID,
                streamID: remoteControlStreamID,
                seqID: seqID
            )
            data = try encoder.encode(envelope)
        } else {
            data = try encoder.encode(message)
        }
        guard let rawMessage = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedMessage
        }
        try await sendWebSocketMessage(.string(rawMessage), on: task)
    }

    private func sendWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on socket: URLSessionWebSocketTask
    ) async throws {
        let retryDelays: [UInt64] = [0, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000]
        var lastError: Error?
        for delay in retryDelays {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                try await socket.send(message)
                return
            } catch {
                guard isTransientSocketNotConnected(error) else {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError ?? AppServerClientError.notConnected
    }

    private func retryDelay(forAttempt attempt: Int) -> UInt64 {
        UInt64(attempt + 1) * 500_000_000
    }

    private func isTransientSocketNotConnected(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 {
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("Socket is not connected")
    }

    private func startReceiveLoop() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let task = self.task {
                do {
                    let message = try await task.receive()
                    try await self.handle(webSocketMessage: message)
                } catch {
                    guard self.task === task else {
                        return
                    }
                    if !self.suppressDisconnectEvents {
                        self.eventContinuation.yield(.disconnected(error.localizedDescription))
                    }
                    self.failPendingRequests(error)
                    self.task = nil
                    return
                }
            }
        }
    }

    private func handle(webSocketMessage: URLSessionWebSocketTask.Message) async throws {
        if connectionMode == .remoteControl {
            try await handleRemoteControl(webSocketMessage: webSocketMessage)
            return
        }

        if let control = CodexRelayWire.control(from: webSocketMessage) {
            switch control.type {
            case "ping":
                if let task {
                    try await sendWebSocketMessage(CodexRelayWire.pongMessage(), on: task)
                }
                return
            case "pong", "register_ack":
                return
            case "relay_error":
                throw AppServerClientError.transport(control.error ?? "Relay connection failed.")
            default:
                break
            }
        }

        let data = try CodexRelayWire.data(from: webSocketMessage)
        let message = try decoder.decode(JSONRPCMessage.self, from: data)
        try handle(jsonRPCMessage: message)
    }

    private func handleRemoteControl(webSocketMessage: URLSessionWebSocketTask.Message) async throws {
        if let control = CodexRelayWire.control(from: webSocketMessage),
           control.type == "relay_error" {
            throw AppServerClientError.transport(control.error ?? "Relay connection failed.")
        }

        let data = try CodexRelayWire.data(from: webSocketMessage)
        let envelope = try decoder.decode(RemoteControlServerEnvelope.self, from: data)
        guard envelope.clientID == remoteControlClientID else {
            return
        }
        switch envelope.type {
        case .serverMessage:
            if let seqID = envelope.seqID {
                try await sendRemoteControlAck(seqID: seqID, streamID: envelope.streamID)
            }
            guard let message = envelope.message else {
                throw AppServerClientError.malformedMessage
            }
            try handle(jsonRPCMessage: message)
        case .ack, .pong:
            return
        }
    }

    private func sendRemoteControlAck(seqID: Int, streamID: String?) async throws {
        guard let task else { throw AppServerClientError.notConnected }
        let envelope = RemoteControlClientEnvelope.ack(
            clientID: remoteControlClientID,
            streamID: streamID ?? remoteControlStreamID,
            seqID: seqID
        )
        let data = try encoder.encode(envelope)
        guard let rawMessage = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedMessage
        }
        try await sendWebSocketMessage(.string(rawMessage), on: task)
    }

    private func handle(jsonRPCMessage message: JSONRPCMessage) throws {
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

    nonisolated static func resumeThreadParams(id threadID: String) -> JSONValue {
        [
            "threadId": .string(threadID),
            "excludeTurns": true,
            "persistExtendedHistory": true,
        ]
    }

    nonisolated static func threadStartParams(cwd: String, settings: CodexSessionSettings) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalsReviewer": "user",
            "approvalPolicy": settings.permissionPreset.approvalPolicy,
            "sandbox": settings.permissionPreset.sandboxMode,
            "experimentalRawEvents": false,
            "persistExtendedHistory": true,
            "serviceTier": .string(settings.serviceTier.rawValue),
        ]
        if let model = settings.model {
            params["model"] = .string(model)
        }
        if let reasoningEffort = settings.reasoningEffort {
            params["config"] = ["model_reasoning_effort": .string(reasoningEffort)]
        }
        return .object(params)
    }

    nonisolated static func turnStartParams(threadID: String, text: String, cwd: String, settings: CodexSessionSettings) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(cwd),
            "input": [
                [
                    "type": "text",
                    "text": .string(text),
                    "text_elements": [],
                ],
            ],
            "approvalsReviewer": "user",
            "approvalPolicy": settings.permissionPreset.approvalPolicy,
            "sandboxPolicy": settings.permissionPreset.turnSandboxPolicy(cwd: cwd),
            "serviceTier": .string(settings.serviceTier.rawValue),
        ]
        if let model = settings.model {
            params["model"] = .string(model)
        }
        if let reasoningEffort = settings.reasoningEffort {
            params["effort"] = .string(reasoningEffort)
        }
        return .object(params)
    }

    nonisolated static func interruptTurnParams(threadID: String, turnID: String?) -> JSONValue {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        if let turnID {
            params["turnId"] = .string(turnID)
        }
        return .object(params)
    }

    nonisolated static func threadTurnsListParams(
        threadID: String,
        limit: Int,
        cursor: String?,
        sortDirection: String
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "limit": .number(Double(limit)),
            "sortDirection": .string(sortDirection),
        ]
        if let cursor {
            params["cursor"] = .string(cursor)
        }
        return .object(params)
    }
}
