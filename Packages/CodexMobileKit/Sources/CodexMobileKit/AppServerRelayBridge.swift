import Foundation

@MainActor
public final class AppServerRelayBridge {
    private var relayTask: URLSessionWebSocketTask?
    private var appServerTask: URLSessionWebSocketTask?
    private var relayToAppTask: Task<Void, Never>?
    private var appToRelayTask: Task<Void, Never>?

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

        let relaySocket = URLSession.shared.webSocketTask(with: relayRequest(url: relayURL, token: pairing.token))
        relayTask = relaySocket
        relaySocket.resume()
        try await registerRelay(socket: relaySocket, pairing: pairing, room: relayRoom)

        let localSocket = URLSession.shared.webSocketTask(with: appServerRequest(pairing: pairing))
        appServerTask = localSocket
        localSocket.resume()

        isRunning = true
        relayToAppTask = Task { @MainActor [weak self] in
            await self?.pumpRelayToApp()
        }
        appToRelayTask = Task { @MainActor [weak self] in
            await self?.pumpAppToRelay()
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

    private func pumpRelayToApp() async {
        guard let relayTask, let appServerTask else { return }
        do {
            while !Task.isCancelled {
                let message = try await relayTask.receive()
                if try await handleRelayControl(message, on: relayTask) {
                    continue
                }
                try await sendWebSocketMessage(message, on: appServerTask)
            }
        } catch {
            stop()
        }
    }

    private func pumpAppToRelay() async {
        guard let relayTask, let appServerTask else { return }
        do {
            while !Task.isCancelled {
                let message = try await appServerTask.receive()
                try await sendWebSocketMessage(message, on: relayTask)
            }
        } catch {
            stop()
        }
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

    private func sendWebSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on socket: URLSessionWebSocketTask
    ) async throws {
        let retryDelays: [UInt64] = [0, 100_000_000, 250_000_000, 500_000_000]
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

    private func isTransientSocketNotConnected(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 {
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("Socket is not connected")
    }
}
