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

The phone receives the LAN address, port, workspace path, and token via a `codex-mobile://pair` QR link. The phone does not log in to OpenAI; it uses the Mac Helper sidecar app-server session.

Relay mode is opt-in from the Mac helper. It keeps the sidecar Codex app-server bound to the Mac and opens an outbound WebSocket tunnel to a relay URL. The relay must not terminate or inspect Codex JSON-RPC; it only matches a `room` and forwards frames between the phone and the Mac helper.

These two Helper modes do not modify the desktop Codex app or its config. They do start a separate app-server process, so the desktop UI will not live-update as if the phone were another window of the same app instance.

Remote Control mode is separate and experimental. It implements Codex app-server's `remote_control` envelope protocol so a desktop app-server can keep its normal stdio transport while opening an outbound public WebSocket to a relay. This is the path for “same desktop instance” access, but it requires desktop Codex remote-control configuration and therefore is not part of the “do not touch desktop” connection path. The mobile app sends normal JSON-RPC methods, but wraps them as `client_message` envelopes and acknowledges `server_message` envelopes with `ack`.

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
- In Remote Control mode, the phone uses the same `/codex-mobile` relay endpoint but registers with `capabilities: ["remote_control_v2"]`. Its pairing link uses `mode=remote-control`, `room=<environment_id>`, and `token=<server_id>`. The relay forwards official Codex remote-control envelopes instead of raw JSON-RPC frames.
- Settings and connection status cards expose reconnect, disconnect, and unpair actions.

## Local Relay Server

A minimal compatible relay is included for development:

```bash
cd /Users/mac/CodexMobile/Tools/relay-server
npm install
PORT=8787 npm start
```

The Helper relay URL for that server is `ws://<relay-host>:8787/codex-mobile`. Use `wss://` when deploying outside a trusted private network.

The same server also exposes a development-compatible Remote Control backend:

```text
POST /backend-api/wham/remote/control/server/enroll
WS   /backend-api/wham/remote/control/server
```

When a Codex app-server enrolls, the relay logs a `codex-mobile://pair?...mode=remote-control` link. Use `PUBLIC_RELAY_WS=wss://your-domain/codex-mobile` when the relay is deployed publicly so the logged pairing link contains the externally reachable phone endpoint.

Desktop Codex currently derives the remote-control backend URL from its `chatgpt_base_url` config and the feature flag `features.remote_control`. Do not point your normal global Codex config at a custom relay unless you are testing intentionally; that setting can affect other ChatGPT-backed app-server calls. The safer production direction is a dedicated desktop helper/profile that enables only the remote-control backend for this app.

For a controlled local experiment with the actual desktop Codex app-server instance:

```bash
cd /Users/mac/CodexMobile/Tools/relay-server
PORT=8787 PUBLIC_RELAY_WS=ws://127.0.0.1:8787/codex-mobile npm start
```

Then, in an isolated Codex config used only for this experiment, enable:

```toml
chatgpt_base_url = "http://127.0.0.1:8787/backend-api/"

[features]
remote_control = true
```

Restart the Codex desktop app with that config. When its stdio app-server enrolls, the relay prints a `codex-mobile://pair?...mode=remote-control` link. That link connects the phone to the same desktop app-server process through remote-control envelopes instead of starting a second app-server.

For public access, keep the app-server backend pointed at a localhost relay because Codex currently restricts remote-control backend URLs to official ChatGPT hosts or localhost. Expose the local relay's `/codex-mobile` phone endpoint with a tunnel or reverse proxy, then set `PUBLIC_RELAY_WS=wss://<domain>/codex-mobile` so the printed pairing link uses the public phone URL while the desktop app-server still connects to `http://127.0.0.1:8787/backend-api/`.
