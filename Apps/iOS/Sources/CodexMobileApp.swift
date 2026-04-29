import CodexMobileKit
import SwiftUI

@main
struct CodexMobileApp: App {
    @StateObject private var store = CodexMobileStore()

    var body: some Scene {
        WindowGroup {
            CodexMobileRootView()
                .environmentObject(store)
                .onOpenURL { url in
                    store.pairingText = url.absoluteString
                    Task { await store.connectFromText() }
                }
                .task {
                    await store.restoreAndConnectIfNeeded()
                }
        }
    }
}

enum MobileConnectionState: Equatable {
    case unpaired
    case connecting
    case connected
    case codexUnavailable(String)
    case tokenRejected
    case disconnected(String)
    case running

    var title: String {
        switch self {
        case .unpaired: "未配对"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .codexUnavailable: "Codex 未启动"
        case .tokenRejected: "Token 失效"
        case .disconnected: "网络断开"
        case .running: "Turn 运行中"
        }
    }

    var detail: String {
        switch self {
        case .unpaired: "扫描 Helper 二维码，或粘贴配对链接。"
        case .connecting: "正在打开局域网会话。"
        case .connected: "可以开始或继续一个 Codex 会话。"
        case let .codexUnavailable(message): message
        case .tokenRejected: "配对 token 已失效，请从 Mac Helper 重新配对。"
        case let .disconnected(message): message
        case .running: "Codex 正在处理当前 turn。"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .running, .connecting: .blue
        case .unpaired: .secondary
        case .codexUnavailable, .tokenRejected, .disconnected: .red
        }
    }
}

@MainActor
final class CodexMobileStore: ObservableObject {
    @Published var connectionState: MobileConnectionState = .unpaired
    @Published var pairingText = ""
    @Published var pairing: PairingPayload?
    @Published var threads: [CodexThread] = []
    @Published var selectedThread: CodexThread?
    @Published var conversation = ConversationState()
    @Published var composerText = ""
    @Published var isScannerPresented = false
    @Published var isSidebarPresented = false
    @Published var isSettingsPresented = false

    private let credentialStore = PairingCredentialStore()
    private var client = AppServerWebSocketClient()
    private var eventTask: Task<Void, Never>?
    private var didAttemptRestore = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var canReconnect: Bool {
        pairing != nil && connectionState != .connecting && connectionState != .running
    }

    var isConnected: Bool {
        switch connectionState {
        case .connected, .running:
            true
        default:
            false
        }
    }

    func restoreAndConnectIfNeeded() async {
        guard !didAttemptRestore, pairing == nil else { return }
        didAttemptRestore = true
        do {
            guard let savedPairing = try credentialStore.load() else { return }
            pairing = savedPairing
            pairingText = savedPairing.deepLinkURL.absoluteString
            try await connect(savedPairing, persist: false)
        } catch {
            connectionState = classifyConnectionError(error)
        }
    }

    func connectFromText() async {
        let payload: PairingPayload
        do {
            payload = try PairingPayload.parse(pairingText)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
            return
        }
        do {
            try await connect(payload)
        } catch {}
    }

    func connect(_ payload: PairingPayload, persist: Bool = true) async throws {
        connectionState = .connecting
        pairing = payload
        pairingText = payload.deepLinkURL.absoluteString
        if persist {
            try? credentialStore.save(payload)
        }
        eventTask?.cancel()
        client.disconnect()
        client = AppServerWebSocketClient()
        observeEvents()
        do {
            try await client.connect(to: payload, appVersion: appVersion)
            connectionState = .connected
            try await loadThreads()
        } catch {
            connectionState = classifyConnectionError(error)
            throw error
        }
    }

    func reconnect() async {
        do {
            if let pairing {
                try await connect(pairing, persist: false)
            } else if let savedPairing = try credentialStore.load() {
                try await connect(savedPairing, persist: false)
            } else {
                connectionState = .unpaired
            }
        } catch {
            connectionState = classifyConnectionError(error)
        }
    }

    func disconnect() {
        eventTask?.cancel()
        client.disconnect()
        selectedThread = nil
        conversation = ConversationState()
        isSettingsPresented = false
        isSidebarPresented = false
        connectionState = pairing == nil ? .unpaired : .disconnected("已手动断开。")
    }

    func forgetPairing() {
        disconnect()
        try? credentialStore.delete()
        pairing = nil
        pairingText = ""
        threads = []
        selectedThread = nil
        conversation = ConversationState()
        connectionState = .unpaired
    }

    func loadDesignPreview() {
        eventTask?.cancel()
        client.disconnect()
        let preview = CodexMobileStore.preview()
        connectionState = preview.connectionState
        pairingText = preview.pairingText
        pairing = preview.pairing
        threads = preview.threads
        selectedThread = preview.selectedThread
        conversation = preview.conversation
        composerText = preview.composerText
        isScannerPresented = false
        isSidebarPresented = false
        isSettingsPresented = false
    }

    func loadThreads() async throws {
        let value = try await client.listThreads()
        threads = CodexThread.parseListResponse(value)
    }

    func startNewThread() async {
        guard let pairing else { return }
        do {
            let value = try await client.startThread(cwd: pairing.cwd)
            guard let thread = CodexThread.parseStartOrResumeResponse(value) else { return }
            selectedThread = thread
            if !threads.contains(where: { $0.id == thread.id }) {
                threads.insert(thread, at: 0)
            }
            conversation = ConversationState(threadID: thread.id)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func select(_ thread: CodexThread) async {
        do {
            let value = try await client.resumeThread(id: thread.id)
            selectedThread = CodexThread.parseStartOrResumeResponse(value) ?? thread
            conversation = ConversationState(threadID: thread.id)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func sendComposerText() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedThread == nil {
            await startNewThread()
        }
        guard let threadID = selectedThread?.id else { return }
        composerText = ""
        conversation.items.append(.init(id: UUID().uuidString, kind: .user, title: "You", body: text))
        do {
            connectionState = .running
            _ = try await client.startTurn(threadID: threadID, text: text)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func interrupt() async {
        guard let threadID = selectedThread?.id else { return }
        do {
            _ = try await client.interruptTurn(threadID: threadID)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func answerApproval(_ decision: String) async {
        guard let approval = conversation.activeApproval else { return }
        do {
            try await client.respondToServerRequest(id: approval.id, result: approval.response(decision: decision))
            conversation.activeApproval = nil
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func observeEvents() {
        eventTask?.cancel()
        eventTask = Task { @MainActor in
            for await event in client.events {
                ConversationReducer.reduce(&conversation, event: event)
                if case let .disconnected(message) = event {
                    connectionState = .disconnected(message)
                } else if conversation.isRunning {
                    connectionState = .running
                } else if case .running = connectionState {
                    connectionState = .connected
                }
            }
        }
    }

    private func classifyConnectionError(_ error: Error) -> MobileConnectionState {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("401") ||
            message.localizedCaseInsensitiveContains("unauthorized")
        {
            return .tokenRejected
        }
        if message.localizedCaseInsensitiveContains("connection refused") ||
            message.localizedCaseInsensitiveContains("could not connect") ||
            message.localizedCaseInsensitiveContains("couldn’t connect") ||
            message.localizedCaseInsensitiveContains("timed out") ||
            message.localizedCaseInsensitiveContains("readiness check") ||
            message.localizedCaseInsensitiveContains("offline")
        {
            return .codexUnavailable("无法连接 Mac Helper 或 Codex app-server。请确认 Mac 端已启动并且手机在同一局域网或 VPN。")
        }
        return .disconnected(message)
    }
}

extension CodexMobileStore {
    static func preview() -> CodexMobileStore {
        let store = CodexMobileStore()
        store.connectionState = .running
        let payload = try? PairingPayload(
            name: "Mac",
            host: "192.168.1.22",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project"
        )
        store.pairing = payload
        store.pairingText = payload?.deepLinkURL.absoluteString ?? ""
        store.threads = [
            CodexThread(id: "thr_1", name: "查看 Codex 项目", preview: "查看 Codex 项目", cwd: "/Users/mac/CodexMobile", status: "loaded", updatedAt: .now.addingTimeInterval(-19 * 60)),
            CodexThread(id: "thr_2", name: "分析 LLM-Wiki 合集", preview: "分析 LLM-Wiki 合集", cwd: "/Users/mac", status: "notLoaded", updatedAt: .now.addingTimeInterval(-18 * 3600)),
            CodexThread(id: "thr_3", name: "Reply to greeting", preview: "Reply to greeting", cwd: "/Users/mac", status: "notLoaded", updatedAt: .now.addingTimeInterval(-86_400)),
            CodexThread(id: "thr_4", name: "撰写答辩PPT演讲稿", preview: "撰写答辩PPT演讲稿", cwd: "/Users/mac", status: "notLoaded", updatedAt: .now.addingTimeInterval(-4 * 86_400)),
            CodexThread(id: "thr_5", name: "Say hi", preview: "Say hi", cwd: "/Users/mac", status: "notLoaded", updatedAt: .now.addingTimeInterval(-5 * 86_400)),
        ]
        store.selectedThread = store.threads.first
        store.conversation = ConversationState(threadID: "thr_1")
        store.conversation.items = [
            ConversationItem(id: "changes", kind: .fileChange, title: "Files changed", body: "", status: "completed"),
            ConversationItem(id: "u1", kind: .user, title: "You", body: "和codex app的显示页面呢"),
        ]
        return store
    }
}
