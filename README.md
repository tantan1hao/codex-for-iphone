# Codex Mobile

Codex Mobile is a new SwiftUI iPhone/iPad client plus a macOS menu-bar helper for controlling the Codex app-server running on a Mac.

## Shape

- `CodexMobile`: iOS/iPadOS app for pairing, thread list, streaming conversation progress, and approval prompts.
- `CodexMobileHelper`: macOS menu-bar helper that launches `codex app-server` over a LAN WebSocket and shows a QR pairing code.
- `Packages/CodexMobileKit`: shared pairing, JSON-RPC, WebSocket, reducer, and helper command-building code.

## Generate And Build

```bash
cd /Users/mac/CodexMobile
xcodegen generate
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
xcodebuild -project CodexMobile.xcodeproj -scheme CodexMobileHelper -destination 'platform=macOS' build
swift test --package-path Packages/CodexMobileKit
```

## MVP Security Boundary

The first version only supports LAN/VPN connections. The helper starts Codex with a high-entropy bearer token:

```bash
codex app-server --listen ws://0.0.0.0:<port> --ws-auth capability-token --ws-token-file <tokenFile>
```

The phone receives the LAN address, port, workspace path, and token via a `codex-mobile://pair` QR link. The phone does not log in to OpenAI; it uses the Mac's Codex app-server session.

