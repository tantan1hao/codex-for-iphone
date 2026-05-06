# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

The Xcode project is generated with XcodeGen. Always run `xcodegen generate` after modifying `project.yml`.

```bash
# Generate Xcode project
cd /Users/mac/CodexMobile
xcodegen generate

# Build iOS app
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Build macOS Helper
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobileHelper \
  -destination 'platform=macOS' build

# Run all Swift package tests
swift test --package-path Packages/CodexMobileKit

# Run a single test class
swift test --package-path Packages/CodexMobileKit --filter PairingPayloadTests

# Start the local relay server for development
cd /Users/mac/CodexMobile/Tools/relay-server
npm install
PORT=8787 npm start
```

Swift 6 strict concurrency is enabled (`SWIFT_VERSION = "6.0"`). All shared mutable state must be `@MainActor` or `Sendable`.

## Architecture

### Three connection modes

Everything in this codebase revolves around three transport modes encoded in `PairingConnectionMode` (in `CodexMobileKit`):

| Mode | Constant | What happens |
|---|---|---|
| `.direct` | `helperLAN` | Phone connects directly to the sidecar app-server over LAN/VPN |
| `.rawRelay` | `helperRelay` | Helper keeps a LAN app-server; relay bridges phone↔app-server |
| `.remoteControl` | `desktopRemoteControl` | Phone wraps JSON-RPC in `remote_control` envelopes; relay talks to the desktop Codex instance |

The `PairingPayload` struct (parsed from a `codex-mobile://pair?...` deep link) carries all the parameters needed to pick and execute a connection mode. `CodexConnectionPlan` (derived from a `PairingPayload`) is the pure-value object that drives all branching in the transport layer — prefer passing a `ConnectionPlan` rather than re-inspecting the payload.

### Packages/CodexMobileKit — shared library

All networking, wire types, and business logic live here. Key files:

- **`PairingPayload.swift`** — parses/serialises the `codex-mobile://pair` deep link URL. Validation happens in `init`; invalid payloads throw `PairingPayloadError`.
- **`ConnectionPlan.swift`** — maps a `PairingPayload` to a `CodexConnectionPlan` that tells the client exactly how to connect (readyz check, relay registration, envelope wrapping).
- **`AppServerWebSocketClient.swift`** — the main JSON-RPC-over-WebSocket client used by the iOS app. Sends requests, streams notifications as `AppServerEvent` via an `AsyncStream`. All methods are `@MainActor`.
- **`AppServerRelayBridge.swift`** — used by the Mac Helper in relay mode. Maintains two WebSocket tasks (relay side and local app-server side) and pumps frames between them. Reconnects the local app-server side on each new `initialize` request.
- **`AppServerWebSocketClient+Features.swift`** — higher-level JSON-RPC calls (filesystem, commands, collaboration modes, automation tasks) as typed methods on the client.
- **`AppServerFeatureModels.swift`** — Codable/JSONValue-backed models for the app-server feature responses.
- **`CodexRelayWire.swift`** — encode/decode relay control frames (`register`, `register_ack`, `ping`, `pong`, `relay_error`).
- **`RemoteControlWire.swift`** — encode/decode the `client_message`/`server_message`/`ack` envelope protocol used in Remote Control mode.
- **`JSONRPC.swift`** — `JSONRPCMessage`, `JSONRPCID`, `AppServerEvent`, `AppServerClientError`.
- **`JSONValue.swift`** — recursive enum used as the untyped JSON container throughout (avoids `Any`).
- **`SessionSettings.swift`** — `CodexSessionSettings`, `CodexPermissionPreset`, `CodexModelOption`.
- **`AppServerCommandBuilder.swift`** — builds the `codex app-server` `Process` launch arguments; resolves the binary path; generates the bearer token via `SecRandomCopyBytes`.
- **`NetworkIdentity.swift`** — resolves the primary LAN address and local hostname for the pairing payload.

### Apps/iOS

`CodexMobileApp` creates a single `CodexMobileStore` (`@StateObject`) that is passed as an `@EnvironmentObject` to the entire view hierarchy. The store owns the `AppServerWebSocketClient` and drives `MobileConnectionState`. On launch it calls `restoreAndConnectIfNeeded()` which reads the last valid pairing from Keychain. Deep links (`codex-mobile://pair?...`) are handled via `.onOpenURL`.

Feature views (`WorkspacePane`, `TerminalFeatureView`, `FilesFeatureView`, `AutomationsFeatureView`, `ContextUsageFeatureView`, `ComposerFeatureControls`) each observe the store and call the appropriate `AppServerWebSocketClient` methods.

### Apps/MacHelper

`HelperController` (`@MainActor ObservableObject`) owns the `Process` for the sidecar app-server and the optional `AppServerRelayBridge`. The start sequence is: generate token → write token file to `~/Library/Application Support/CodexMobileHelper/` → launch `codex app-server` → poll `/readyz` → optionally start relay bridge → set status to `.ready` → render QR code from the deep link URL.

### Tools/relay-server

A minimal Node.js WebSocket relay for local development. Rooms are matched by `room` field in the registration frame. It also exposes the remote-control enrollment endpoints so the actual desktop Codex app-server can be tested end-to-end locally. See README for the `PUBLIC_RELAY_WS` environment variable needed to make the logged pairing link externally reachable.

## JSONValue conventions

`JSONValue` is used everywhere instead of `[String: Any]`. Literal syntax is supported via `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`, etc., and dictionary/array literals. Access values with `.stringValue`, `.boolValue`, `.numberValue`, `.arrayValue`, `.objectValue`.

## Security notes

- The bearer token is written to `~/Library/Application Support/CodexMobileHelper/codex-mobile-token` with mode `0600` and passed to `codex app-server` via `--ws-token-file`.
- The iOS app stores the pairing payload in Keychain; it is never logged.
- Relay mode is opt-in; LAN/VPN direct mode is the default.
- Remote Control mode requires changes to the desktop Codex config (`chatgpt_base_url`, `features.remote_control`) — do not modify the user's global Codex config for this.
