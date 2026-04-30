import Foundation

public enum CodexConnectionTransport: String, Equatable, Sendable {
    case helperLAN
    case helperRelay
    case desktopRemoteControl
}

public struct CodexConnectionPlan: Equatable, Sendable {
    public var transport: CodexConnectionTransport
    public var webSocketURL: URL
    public var readyzURL: URL?
    public var registersRelay: Bool
    public var usesRemoteControlEnvelope: Bool
    public var requiresDesktopAppConfiguration: Bool
    public var launchesHelperSidecarAppServer: Bool

    public init(pairing: PairingPayload) {
        self.webSocketURL = pairing.websocketURL
        switch pairing.connectionMode {
        case .direct:
            self.transport = .helperLAN
            self.readyzURL = pairing.readyzURL
            self.registersRelay = false
            self.usesRemoteControlEnvelope = false
            self.requiresDesktopAppConfiguration = false
            self.launchesHelperSidecarAppServer = true
        case .rawRelay:
            self.transport = .helperRelay
            self.readyzURL = nil
            self.registersRelay = true
            self.usesRemoteControlEnvelope = false
            self.requiresDesktopAppConfiguration = false
            self.launchesHelperSidecarAppServer = true
        case .remoteControl:
            self.transport = .desktopRemoteControl
            self.readyzURL = nil
            self.registersRelay = true
            self.usesRemoteControlEnvelope = true
            self.requiresDesktopAppConfiguration = true
            self.launchesHelperSidecarAppServer = false
        }
    }

    public var canRunWithoutDesktopAppChanges: Bool {
        !requiresDesktopAppConfiguration
    }

    public var displayTitle: String {
        switch transport {
        case .helperLAN: "Helper LAN"
        case .helperRelay: "Helper Relay"
        case .desktopRemoteControl: "Desktop Remote Control"
        }
    }

    public var detail: String {
        switch transport {
        case .helperLAN:
            "Mac Helper starts a sidecar Codex app-server and the phone connects over LAN/VPN."
        case .helperRelay:
            "Mac Helper starts a sidecar Codex app-server and tunnels it through the relay."
        case .desktopRemoteControl:
            "The phone connects to the desktop app-server through Codex remote_control envelopes."
        }
    }
}

public extension PairingPayload {
    var connectionPlan: CodexConnectionPlan {
        CodexConnectionPlan(pairing: self)
    }
}

