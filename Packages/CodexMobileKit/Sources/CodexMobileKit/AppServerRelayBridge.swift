import Foundation

@MainActor
public final class AppServerRelayBridge {
    private var relayTask: URLSessionWebSocketTask?
    private var appServerTask: URLSessionWebSocketTask?
    private var relayToAppTask: Task<Void, Never>?
    private var appToRelayTask: Task<Void, Never>?
    private var pairing: PairingPayload?
    private var didForwardInitialize = false

    public private(set) var isRunning = false

    public init() {}

    deinit {
        relayTask?.cancel(with: .goingAway, reason: nil)
        appServerTask?.cancel(with: .goingAway, reason: nil)
        relayToAppTask?.cancel()
        appToRelayTask?.cancel()
    }

    public func start(pairing: PairingPayload) async throws {
        guard pairing.usesRawRelay,
              let relayURL = pairing.relayURL,
              let relayRoom = pairing.relayRoom
        else {
            throw AppServerClientError.transport("Pairing payload is not configured for relay.")
        }
        stop()
        self.pairing = pairing
        didForwardInitialize = false

        let relaySocket = try await openRelaySocket(relayURL: relayURL, pairing: pairing, room: relayRoom)
        relayTask = relaySocket

        isRunning = true
        relayToAppTask = Task { @MainActor [weak self] in
            await self?.pumpRelayToApp(relayTask: relaySocket)
        }
    }

    public func stop() {
        relayToAppTask?.cancel()
        appToRelayTask?.cancel()
        relayToAppTask = nil
        appToRelayTask = nil
        relayTask?.cancel(with: .goingAway, reason: nil)
        appServerTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        appServerTask = nil
        pairing = nil
        didForwardInitialize = false
        isRunning = false
    }

    private func relayRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func appServerRequest(pairing: PairingPayload) -> URLRequest {
        let url = URL(string: "ws://127.0.0.1:\(pairing.port)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func openRelaySocket(
        relayURL: URL,
        pairing: PairingPayload,
        room: String
    ) async throws -> URLSessionWebSocketTask {
        let request = relayRequest(url: relayURL, token: pairing.token)
        var lastError: Error?

        for attempt in 0..<4 {
            let socket = URLSession.shared.webSocketTask(with: request)
            relayTask = socket
            socket.resume()

            do {
                try await registerRelay(socket: socket, pairing: pairing, room: room)
                return socket
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                if relayTask === socket {
                    relayTask = nil
                }
                guard isTransientSocketNotConnected(error), attempt < 3 else {
                    throw error
                }
                lastError = error
                try await Task.sleep(nanoseconds: retryDelay(forAttempt: attempt))
            }
        }

        throw lastError ?? AppServerClientError.notConnected
    }

    private func registerRelay(socket: URLSessionWebSocketTask, pairing: PairingPayload, room: String) async throws {
        let registration = CodexRelayRegistration(
            role: .mac,
            room: room,
            name: pairing.name,
            token: pairing.token,
            metadata: [
                "adapter": "codex_mobile_helper",
                "cwd": .string(pairing.cwd),
                "localPort": .number(Double(pairing.port)),
            ]
        )
        try await sendWebSocketMessage(.string(CodexRelayWire.registrationString(registration)), on: socket)
        let acknowledgement = try CodexRelayWire.acknowledgement(from: try await socket.receive())
        guard acknowledgement.type == "register_ack", acknowledgement.ok else {
            throw AppServerClientError.transport(acknowledgement.error ?? "Relay registration was rejected.")
        }
    }

    private func pumpRelayToApp(relayTask: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await relayTask.receive()
                if try await handleRelayControl(message, on: relayTask) {
                    continue
                }
                let startsNewSession = isInitializeRequest(message)
                if startsNewSession, didForwardInitialize {
                    try restartAppServerConnection(relayTask: relayTask)
                }
                let appServerTask = try ensureAppServerConnection(relayTask: relayTask)
                try await sendWebSocketMessage(message, on: appServerTask)
                if startsNewSession {
                    didForwardInitialize = true
                }
            }
        } catch {
            stop()
        }
    }

    private func pumpAppToRelay(relayTask: URLSessionWebSocketTask, appServerTask: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await appServerTask.receive()
                try await sendWebSocketMessage(message, on: relayTask)
            }
        } catch {
            if self.appServerTask === appServerTask {
                stop()
            }
        }
    }

    private func ensureAppServerConnection(relayTask: URLSessionWebSocketTask) throws -> URLSessionWebSocketTask {
        if let appServerTask {
            return appServerTask
        }
        guard let pairing else {
            throw AppServerClientError.notConnected
        }
        let socket = URLSession.shared.webSocketTask(with: appServerRequest(pairing: pairing))
        appServerTask = socket
        socket.resume()
        appToRelayTask?.cancel()
        appToRelayTask = Task { @MainActor [weak self] in
            await self?.pumpAppToRelay(relayTask: relayTask, appServerTask: socket)
        }
        return socket
    }

    private func restartAppServerConnection(relayTask: URLSessionWebSocketTask) throws {
        appToRelayTask?.cancel()
        appToRelayTask = nil
        appServerTask?.cancel(with: .goingAway, reason: nil)
        appServerTask = nil
        didForwardInitialize = false
        _ = try ensureAppServerConnection(relayTask: relayTask)
    }

    private func handleRelayControl(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let control = CodexRelayWire.control(from: message) else { return false }
        switch control.type {
        case "ping":
            try await sendWebSocketMessage(CodexRelayWire.pongMessage(), on: socket)
            return true
        case "pong", "register_ack":
            return true
        case "relay_error":
            throw AppServerClientError.transport(control.error ?? "Relay connection failed.")
        default:
            return false
        }
    }

    private func isInitializeRequest(_ message: URLSessionWebSocketTask.Message) -> Bool {
        guard let data = try? CodexRelayWire.data(from: message),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return object["method"] as? String == "initialize"
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
}
