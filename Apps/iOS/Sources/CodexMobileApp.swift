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
    @Published private(set) var isSendingComposer = false
    @Published private(set) var isUpdatingSessionSettings = false
    @Published var availableModels: [CodexModelOption] = [.fallback]
    @Published var selectedModelID = CodexModelOption.fallback.model
    @Published var selectedReasoningEffort = "xhigh"
    @Published var selectedPermissionPreset: CodexPermissionPreset = .workspaceWrite

    private let credentialStore = PairingCredentialStore()
    private var client = AppServerWebSocketClient()
    private var eventTask: Task<Void, Never>?
    private var didAttemptRestore = false
    private var isDesignPreviewMode = false

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var canReconnect: Bool {
        pairing != nil && connectionState != .connecting && connectionState != .running
    }

    var canSendComposer: Bool {
        isConnected &&
            !conversation.isRunning &&
            !isSendingComposer &&
            !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canInterruptTurn: Bool {
        isConnected && conversation.isRunning && selectedThread != nil
    }

    var canStartThread: Bool {
        isConnected && !conversation.isRunning && !isSendingComposer
    }

    var canChangeSessionSettings: Bool {
        isConnected && !conversation.isRunning && !isSendingComposer && !isUpdatingSessionSettings
    }

    var selectedModel: CodexModelOption {
        availableModels.first { $0.model == selectedModelID || $0.id == selectedModelID } ?? CodexModelOption(
            id: selectedModelID,
            model: selectedModelID,
            displayName: selectedModelID,
            defaultReasoningEffort: selectedReasoningEffort,
            supportedReasoningEfforts: ["medium", "high", "xhigh"]
        )
    }

    var availableReasoningEfforts: [String] {
        let efforts = selectedModel.supportedReasoningEfforts
        return efforts.isEmpty ? ["medium", "high", "xhigh"] : efforts
    }

    var modelStatusTitle: String {
        "\(shortModelName(selectedModel.displayName)) \(reasoningEffortTitle(selectedReasoningEffort))"
    }

    var compactModelStatusTitle: String {
        shortModelName(selectedModel.displayName)
    }

    var permissionStatusTitle: String {
        selectedPermissionPreset.displayTitle
    }

    var compactPermissionStatusTitle: String {
        selectedPermissionPreset.compactTitle
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
        isDesignPreviewMode = false
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
            await refreshSessionConfiguration(cwd: payload.cwd)
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
        isDesignPreviewMode = false
        eventTask?.cancel()
        client.disconnect()
        selectedThread = nil
        conversation = ConversationState()
        isSendingComposer = false
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
        isDesignPreviewMode = true
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
        isSendingComposer = false
        isScannerPresented = false
        isSidebarPresented = false
        isSettingsPresented = false
        availableModels = preview.availableModels
        selectedModelID = preview.selectedModelID
        selectedReasoningEffort = preview.selectedReasoningEffort
        selectedPermissionPreset = preview.selectedPermissionPreset
    }

    func loadThreads() async throws {
        let value = try await client.listThreads()
        threads = CodexThread.parseListResponse(value)
    }

    func startNewThread() async {
        guard let pairing else { return }
        if isDesignPreviewMode {
            let thread = CodexThread(
                id: "preview-\(UUID().uuidString)",
                name: "新对话",
                preview: "新对话",
                cwd: pairing.cwd,
                status: "loaded",
                updatedAt: .now
            )
            selectedThread = thread
            threads.insert(thread, at: 0)
            conversation = ConversationState(threadID: thread.id)
            return
        }
        do {
            let value = try await client.startThread(cwd: pairing.cwd, settings: currentSessionSettings)
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
        selectedThread = thread
        conversation = ConversationState(threadID: thread.id)
        guard isConnected, !isDesignPreviewMode else { return }
        do {
            let value = try await client.resumeThread(id: thread.id)
            selectedThread = CodexThread.parseStartOrResumeResponse(value) ?? thread
            conversation = ConversationReducer.state(fromThreadResponse: value, fallbackThreadID: thread.id)
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func sendComposerText() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendComposer else { return }
        isSendingComposer = true
        defer { isSendingComposer = false }
        if selectedThread == nil {
            await startNewThread()
        }
        guard let threadID = selectedThread?.id else { return }
        composerText = ""
        let userItem = ConversationItem(id: UUID().uuidString, kind: .user, title: "You", body: text)
        var updatedConversation = conversation
        updatedConversation.items.append(userItem)
        conversation = updatedConversation
        if isDesignPreviewMode {
            updatedConversation = conversation
            updatedConversation.items.append(
                ConversationItem(
                    id: UUID().uuidString,
                    kind: .assistant,
                    title: "Codex",
                    body: "预览模式已收到消息。真实连接后会通过 Codex app-server 返回流式回复。"
                )
            )
            conversation = updatedConversation
            return
        }
        do {
            connectionState = .running
            let cwd = selectedThread?.cwd.isEmpty == false ? selectedThread?.cwd ?? "" : pairing?.cwd ?? ""
            _ = try await client.startTurn(threadID: threadID, text: text, cwd: cwd, settings: currentSessionSettings)
        } catch {
            updatedConversation = conversation
            if let index = updatedConversation.items.firstIndex(where: { $0.id == userItem.id }) {
                updatedConversation.items[index].status = "failed"
            }
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText = text
            }
            updatedConversation.items.append(
                ConversationItem(
                    id: UUID().uuidString,
                    kind: .error,
                    title: "发送失败",
                    body: error.localizedDescription
                )
            )
            conversation = updatedConversation
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func changeModel(to model: CodexModelOption) async {
        guard canChangeSessionSettings else { return }
        let previous = selectedModelID
        let previousEffort = selectedReasoningEffort
        selectedModelID = model.model
        if !model.supportedReasoningEfforts.isEmpty,
           !model.supportedReasoningEfforts.contains(selectedReasoningEffort)
        {
            selectedReasoningEffort = model.defaultReasoningEffort ?? model.supportedReasoningEfforts.first ?? selectedReasoningEffort
        }
        await writeSessionSettings(
            edits: [
                ("model", .string(model.model)),
                ("model_reasoning_effort", .string(selectedReasoningEffort)),
            ],
            rollback: {
                self.selectedModelID = previous
                self.selectedReasoningEffort = previousEffort
            }
        )
    }

    func changeReasoningEffort(to effort: String) async {
        guard canChangeSessionSettings else { return }
        let previous = selectedReasoningEffort
        selectedReasoningEffort = effort
        await writeSessionSettings(
            edits: [("model_reasoning_effort", .string(effort))],
            rollback: {
                self.selectedReasoningEffort = previous
            }
        )
    }

    func changePermissionPreset(to preset: CodexPermissionPreset) async {
        guard canChangeSessionSettings else { return }
        let previous = selectedPermissionPreset
        selectedPermissionPreset = preset
        await writeSessionSettings(
            edits: [
                ("approval_policy", preset.approvalPolicy),
                ("sandbox_mode", preset.sandboxMode),
            ],
            rollback: {
                self.selectedPermissionPreset = previous
            }
        )
    }

    func interrupt() async {
        guard canInterruptTurn, let threadID = selectedThread?.id else { return }
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
            var updatedConversation = conversation
            updatedConversation.activeApproval = nil
            conversation = updatedConversation
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func observeEvents() {
        eventTask?.cancel()
        eventTask = Task { @MainActor in
            for await event in client.events {
                var updatedConversation = conversation
                ConversationReducer.reduce(&updatedConversation, event: event)
                conversation = updatedConversation
                if case let .disconnected(message) = event {
                    connectionState = .disconnected(message)
                } else if updatedConversation.isRunning {
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

    private var currentSessionSettings: CodexSessionSettings {
        CodexSessionSettings(
            model: selectedModelID,
            reasoningEffort: selectedReasoningEffort,
            permissionPreset: selectedPermissionPreset
        )
    }

    private func refreshSessionConfiguration(cwd: String) async {
        do {
            let modelValue = try await client.listModels()
            let models = CodexModelOption.parseListResponse(modelValue)
            if !models.isEmpty {
                availableModels = models.filter { !$0.displayName.isEmpty }
            }
        } catch {
            availableModels = [.fallback]
        }

        do {
            let configValue = try await client.readConfig(cwd: cwd)
            let config = configValue.objectValue?["config"]?.objectValue ?? [:]
            if let model = config["model"]?.stringValue, !model.isEmpty {
                selectedModelID = model
                if !availableModels.contains(where: { $0.model == model || $0.id == model }) {
                    availableModels.insert(
                        CodexModelOption(
                            id: model,
                            model: model,
                            displayName: model,
                            defaultReasoningEffort: config["model_reasoning_effort"]?.stringValue
                        ),
                        at: 0
                    )
                }
            } else if let defaultModel = availableModels.first(where: \.isDefault) ?? availableModels.first {
                selectedModelID = defaultModel.model
            }
            if let effort = config["model_reasoning_effort"]?.stringValue, !effort.isEmpty {
                selectedReasoningEffort = effort
            } else if let defaultEffort = selectedModel.defaultReasoningEffort {
                selectedReasoningEffort = defaultEffort
            }
            selectedPermissionPreset = CodexPermissionPreset.fromConfig(
                approvalPolicy: config["approval_policy"],
                sandboxMode: config["sandbox_mode"]
            )
        } catch {
            if let defaultModel = availableModels.first(where: \.isDefault) ?? availableModels.first {
                selectedModelID = defaultModel.model
                selectedReasoningEffort = defaultModel.defaultReasoningEffort ?? selectedReasoningEffort
            }
        }
    }

    private func writeSessionSettings(edits: [(String, JSONValue)], rollback: @escaping () -> Void) async {
        guard !isDesignPreviewMode else { return }
        isUpdatingSessionSettings = true
        defer { isUpdatingSessionSettings = false }
        do {
            try await client.writeConfigValues(edits)
        } catch {
            rollback()
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    private func shortModelName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "Codex", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reasoningEffortTitle(_ value: String) -> String {
        switch value {
        case "minimal": "极低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "超高"
        default: value
        }
    }
}

extension CodexMobileStore {
    static func preview() -> CodexMobileStore {
        let store = CodexMobileStore()
        store.connectionState = .connected
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
        var conversation = ConversationState(threadID: "thr_1")
        conversation.items = [
            ConversationItem(id: "changes", kind: .fileChange, title: "Files changed", body: "", status: "completed"),
            ConversationItem(id: "u1", kind: .user, title: "You", body: "和codex app的显示页面呢"),
        ]
        store.conversation = conversation
        store.availableModels = [
            CodexModelOption(
                id: "gpt-5.5",
                model: "gpt-5.5",
                displayName: "GPT-5.5",
                defaultReasoningEffort: "xhigh",
                supportedReasoningEfforts: ["medium", "high", "xhigh"],
                isDefault: true
            ),
            CodexModelOption(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                defaultReasoningEffort: "high",
                supportedReasoningEfforts: ["medium", "high", "xhigh"]
            ),
        ]
        store.selectedModelID = "gpt-5.5"
        store.selectedReasoningEffort = "xhigh"
        store.selectedPermissionPreset = .fullAccess
        return store
    }
}
