# NanoClaw iOS — Project Structure

## Xcode Project Setup

Create a new Xcode project:
- Template: iOS → App
- Product Name: NanoClaw
- Team: (your team)
- Organization Identifier: com.nanoclaw
- Interface: SwiftUI
- Language: Swift
- Minimum Deployment: iOS 17.0

## Swift Package Dependencies

Add via Xcode → File → Add Package Dependencies:

| Package | URL | Version |
|---------|-----|---------|
| MarkdownUI | `https://github.com/gonzalezreal/swift-markdown-ui` | 2.4.0+ |

## File Layout

```
NanoClaw/
├── NanoClawApp.swift              # @main entry point, scene setup
├── Models/
│   ├── Message.swift              # Chat message model
│   └── ConnectionConfig.swift     # Host/port config (UserDefaults-backed)
├── Services/
│   ├── KeychainService.swift      # Keychain read/write/delete for auth token
│   └── WebSocketService.swift     # URLSessionWebSocketTask manager, reconnect logic
├── Views/
│   ├── ChatView.swift             # Main chat screen with message list + input
│   ├── MessageBubble.swift        # Single message bubble with Markdown rendering
│   ├── TypingIndicator.swift      # Animated 3-dot "AI is typing" indicator
│   └── SettingsView.swift         # Host, port, token config + test connection
```

## Build Settings

- SWIFT_VERSION: 5.9+
- IPHONEOS_DEPLOYMENT_TARGET: 17.0
- Enable "Strict Concurrency Checking": Complete

## Capabilities

No special capabilities or entitlements required. The app communicates over
standard WebSocket (URLSession) to a Tailscale host reachable from the device's
network (requires the Tailscale VPN app to be active on the iOS device).

## Running

1. Install the Tailscale iOS app and join your tailnet.
2. Build and run this app on a device or simulator.
3. Open Settings, enter your host (default: `nanoclaw`), port, and auth token.
4. Tap "Test Connection" to verify.
5. Return to chat and start messaging.
