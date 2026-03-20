# NanoClaw iOS — Claude Code Context

## 项目概述

NanoClaw iOS 是一个 SwiftUI 原生 app，通过 WebSocket over Tailscale 与 Rust 后端通信，Rust 后端再通过文件 IPC 与 NanoClaw AI agent 交互。

```
iPhone (SwiftUI)
    ↕ WebSocket / Tailscale Magic DNS
Rust 后端 (launchd agent, Mac 本地)
    ↕ 文件 IPC (/workspace/ipc/)
NanoClaw Agent (Docker 容器, Node.js)
    ↕
Claude API (Anthropic)
```

## 项目结构

```
NanoClaw/
├── NanoClawApp.swift           — App 入口，注入 WebSocketService
├── Models/
│   ├── Message.swift           — 消息模型 (id: UUID, role, text, timestamp)
│   └── ConnectionConfig.swift  — UserDefaults 配置 (host, port, webSocketURL)
├── Services/
│   ├── KeychainService.swift   — Keychain 封装，存储 auth token
│   └── WebSocketService.swift  — 核心 WebSocket 管理器 (@MainActor, ObservableObject)
└── Views/
    ├── ChatView.swift          — 主聊天界面
    ├── MessageBubble.swift     — 消息气泡 (用户: 紫色渐变, AI: 深灰 + Markdown)
    ├── TypingIndicator.swift   — 三点动画等待指示器
    └── SettingsView.swift      — 设置页 (host/port/token 配置)
```

## WebSocket 协议

```json
// 鉴权 (首帧)
Client → Server: { "auth": "<token>" }
Server → Client: { "type": "auth_ok", "session_id": "..." }
Server → Client: { "type": "auth_err", "message": "..." }

// 对话
Client → Server: { "type": "message", "text": "hello" }
Server → Client: { "type": "token", "text": "Hi" }     // 流式
Server → Client: { "type": "done" }                    // 完成
Server → Client: { "type": "error", "message": "..." }

// 心跳
Client → Server: { "type": "ping" }
Server → Client: { "type": "pong" }
```

## 已知问题 (需要修复)

### 1. 黑屏问题
- 首次启动 app 显示黑屏
- 可能原因：
  a. MarkdownUI SPM 包未解析 → 在 Xcode: File → Packages → Resolve Package Versions
  b. Keychain 无 token 时 connect() 返回 .error 状态，界面可能未正确渲染
  c. 需确认 ChatView 在所有 connectionState 下都能渲染

### 2. 编译错误 (已修复)
- ChatView.swift:67 — `UUID? ?? String` 类型不匹配 ✅ 已修复

## SPM 依赖

- `swift-markdown-ui` (gonzalezreal/swift-markdown-ui, >= 2.3.0)
- 在 Xcode 中首次打开需要 File → Packages → Resolve Package Versions

## 连接配置 (首次使用)

在 App 的 Settings 页填入：
- Host: `nanoclaw`（Tailscale Magic DNS）或 Tailscale IP
- Port: `8080`
- Token: 与 Rust 后端 `.env` 里的 `IOS_CHANNEL_SECRET` 一致

Token 存储在 Keychain，Host/Port 存储在 UserDefaults。

## Rust 后端代码位置

`~/Dev/nanoclaw/groups/discord_main/ios-dev/nanoclaw-ios-rust/`

- 用 `tokio` + `axum` 实现 WebSocket 服务器
- 默认监听 `0.0.0.0:8080`
- 通过文件 IPC 与 NanoClaw 通信

## 修复建议优先级

1. **先验证基础渲染**：把 MessageBubble 中的 `Markdown(message.text)` 临时换成 `Text(message.text)` 排除 MarkdownUI 问题
2. **首次启动 UX**：无 token 时直接跳到 SettingsView，而不是显示空的 ChatView
3. **恢复 MarkdownUI**：基础功能验证后再加回 Markdown 渲染
