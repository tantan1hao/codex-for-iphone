# Codex Mobile

Codex Mobile is a new SwiftUI iPhone/iPad client plus a macOS menu-bar helper for controlling the Codex app-server running on a Mac.

## Shape

- `CodexMobile`: iOS/iPadOS app for pairing, thread list, streaming conversation progress, and approval prompts.
- `CodexMobileHelper`: macOS menu-bar helper that launches `codex app-server` over a LAN WebSocket and shows a QR pairing code. It can also open an outbound relay tunnel for non-LAN use.
- `Packages/CodexMobileKit`: shared pairing, JSON-RPC, WebSocket, reducer, and helper command-building code.

## Generate And Build

```bash
cd /Users/mac/CodexMobile
xcodegen generate
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobileHelper -destination 'platform=macOS' build
swift test --package-path Packages/CodexMobileKit
```

## Security Boundary

The default connection mode is LAN/VPN. The helper starts Codex with a high-entropy bearer token:

```bash
codex app-server --listen ws://0.0.0.0:<port> --ws-auth capability-token --ws-token-file <tokenFile>
```

The phone receives the LAN address, port, workspace path, and token via a `codex-mobile://pair` QR link. The phone does not log in to OpenAI; it uses the Mac's Codex app-server session.

Relay mode is opt-in from the Mac helper. It keeps Codex app-server bound to the Mac process and opens an outbound WebSocket tunnel to a relay URL. The relay must not terminate or inspect Codex JSON-RPC; it only matches a `room` and forwards frames between the phone and the Mac helper.

## Connection Flow

- The iOS app stores the last valid pairing link in Keychain and attempts one foreground reconnect on launch.
- In LAN mode, before opening the WebSocket, the client checks `http://<host>:<port>/readyz` so “Codex not started” is shown before JSON-RPC initialization.
- In relay mode, both sides connect to the relay and send a cc-connect style registration frame before any Codex JSON-RPC:

```json
{
  "type": "register",
  "v": 1,
  "platform": "codex_mobile",
  "role": "phone",
  "capabilities": ["raw_jsonrpc_tunnel", "ping_pong"],
  "room": "<pairing room>",
  "name": "Codex Mobile",
  "token": "<bearer token>",
  "metadata": { "adapter": "codex_mobile_ios" }
}
```

The relay replies with `{"type":"register_ack","ok":true}`. After that, every non-control WebSocket message is forwarded unchanged. Control frames currently supported by clients are `ping`, `pong`, `register_ack`, and `relay_error`.
- Settings and connection status cards expose reconnect, disconnect, and unpair actions.

## Local Relay Server

A minimal compatible relay is included for development:

```bash
cd /Users/mac/CodexMobile/Tools/relay-server
npm install
PORT=8787 npm start
```

The Helper relay URL for that server is `ws://<relay-host>:8787/codex-mobile`. Use `wss://` when deploying outside a trusted private network.
