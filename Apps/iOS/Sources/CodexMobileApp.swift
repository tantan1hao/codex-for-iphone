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
    case preview
    case connecting
    case connected
    case codexUnavailable(String)
    case tokenRejected
    case disconnected(String)
    case running

    var title: String {
        switch self {
        case .unpaired: "未配对"
        case .preview: "界面预览"
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
        case .preview: "当前是本地 UI 预览，不会连接电脑 Codex，也不会返回真实结果。"
        case .connecting: "正在打开 Codex 连接。"
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
        case .preview: .orange
        case .running, .connecting: .blue
        case .unpaired: .secondary
        case .codexUnavailable, .tokenRejected, .disconnected: .red
        }
    }
}

struct HistoryContentNotice: Equatable {
    var icon: String
    var title: String
    var detail: String

    static let oversized = HistoryContentNotice(
        icon: "exclamationmark.arrow.triangle.2.circlepath",
        title: "历史内容过大",
        detail: "已跳过旧消息并重新连接；后续消息会从这里显示。"
    )

    static let olderContentOversized = HistoryContentNotice(
        icon: "exclamationmark.arrow.triangle.2.circlepath",
        title: "更早历史过大",
        detail: "已停止继续加载旧消息；当前会话可以继续发送和接收新消息。"
    )
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
    @Published private(set) var isLoadingHistoryContent = false
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var historyNextCursor: String?
    @Published private(set) var historyContentNotice: HistoryContentNotice?
    @Published var shouldLoadHistoryContent = UserDefaults.standard.object(forKey: "CodexMobile.shouldLoadHistoryContent") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(shouldLoadHistoryContent, forKey: Self.historyContentPreferenceKey)
        }
    }
    @Published var availableModels: [CodexModelOption] = [.fallback]
    @Published var selectedModelID = CodexModelOption.fallback.model
    @Published var selectedReasoningEffort = "xhigh"
    @Published var selectedPermissionPreset: CodexPermissionPreset = .workspaceWrite

    private static let historyContentPreferenceKey = "CodexMobile.shouldLoadHistoryContent"
    private static let historyPageLimit = 1
    private let credentialStore = PairingCredentialStore()
    private var client = AppServerWebSocketClient()
    private var eventTask: Task<Void, Never>?
    private var didAttemptRestore = false
    private var isDesignPreviewMode = false
    private var oversizedHistoryThreadIDs = Set<String>()

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var canReconnect: Bool {
        pairing != nil &&
            !isDesignPreviewMode &&
            connectionState != .connecting &&
            connectionState != .running
    }

    var canSendComposer: Bool {
        isConnected &&
            !isDesignPreviewMode &&
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

    var shouldShowHistoryDisabledNotice: Bool {
        selectedThread != nil &&
            !shouldLoadHistoryContent &&
            conversation.items.isEmpty &&
            !isLoadingHistoryContent
    }

    var canLoadMoreHistory: Bool {
        shouldLoadHistoryContent &&
            historyNextCursor != nil &&
            historyContentNotice == nil &&
            selectedThread != nil &&
            !isLoadingHistoryContent &&
            !isLoadingMoreHistory
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

    var isPreviewMode: Bool {
        isDesignPreviewMode
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
        threads = []
        selectedThread = nil
        conversation = ConversationState()
        composerText = ""
        isSendingComposer = false
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = nil
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
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = nil
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
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = nil
        connectionState = .unpaired
    }

    func loadDesignPreview() {
        isDesignPreviewMode = true
        eventTask?.cancel()
        client.disconnect()
        let preview = CodexMobileStore.preview()
        connectionState = .preview
        pairingText = preview.pairingText
        pairing = preview.pairing
        threads = preview.threads
        selectedThread = preview.selectedThread
        conversation = preview.conversation
        composerText = preview.composerText
        isSendingComposer = false
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = nil
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
            historyContentNotice = nil
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
            historyContentNotice = nil
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func select(_ thread: CodexThread) async {
        selectedThread = thread
        conversation = ConversationState(threadID: thread.id)
        historyNextCursor = nil
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyContentNotice = nil
        guard isConnected, !isDesignPreviewMode else { return }
        do {
            let value = try await client.resumeThread(id: thread.id)
            // Only apply if the user hasn't already switched away
            guard selectedThread?.id == thread.id else { return }
            selectedThread = CodexThread.parseStartOrResumeResponse(value) ?? thread
            if shouldLoadHistoryContent {
                if oversizedHistoryThreadIDs.contains(thread.id) {
                    historyContentNotice = .oversized
                    conversation = ConversationState(threadID: thread.id)
                    return
                }
                isLoadingHistoryContent = true
                let turnsValue = try await client.listThreadTurns(threadID: thread.id, limit: Self.historyPageLimit)
                guard selectedThread?.id == thread.id, shouldLoadHistoryContent else { return }
                conversation = ConversationReducer.state(fromTurnsListResponse: turnsValue, threadID: thread.id)
                historyNextCursor = ConversationReducer.nextCursor(fromTurnsListResponse: turnsValue)
                isLoadingHistoryContent = false
            } else {
                conversation = ConversationState(threadID: thread.id)
            }
        } catch {
            // Don't tear down the whole connection just because one thread
            // failed to resume — keep the composer usable.
            guard selectedThread?.id == thread.id else { return }
            isLoadingHistoryContent = false
            historyNextCursor = nil
            if isMessageTooLong(error) {
                await handleOversizedHistory(thread: thread)
                return
            }
            var errorConversation = ConversationState(threadID: thread.id)
            errorConversation.items.append(
                ConversationItem(
                    id: "resume-error-\(thread.id)",
                    kind: .error,
                    title: "无法加载会话",
                    body: error.localizedDescription
                )
            )
            conversation = errorConversation
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
        do {
            connectionState = .running
            let cwd = selectedThread?.cwd.isEmpty == false ? selectedThread?.cwd ?? "" : pairing?.cwd ?? ""
            _ = try await client.startTurn(threadID: threadID, text: text, cwd: cwd, settings: currentSessionSettings)
        } catch {
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText = text
            }
            var updatedConversation = conversation
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

    func loadMoreHistory() async {
        guard shouldLoadHistoryContent,
              !isLoadingMoreHistory,
              let threadID = selectedThread?.id,
              let cursor = historyNextCursor,
              historyContentNotice == nil
        else { return }
        isLoadingMoreHistory = true
        do {
            let value = try await client.listThreadTurns(threadID: threadID, limit: Self.historyPageLimit, cursor: cursor)
            guard selectedThread?.id == threadID, shouldLoadHistoryContent else { return }
            let olderState = ConversationReducer.state(fromTurnsListResponse: value, threadID: threadID)
            var updatedConversation = conversation
            let existingIDs = Set(updatedConversation.items.map(\.id))
            let olderItems = olderState.items.filter { !existingIDs.contains($0.id) }
            updatedConversation.items.insert(contentsOf: olderItems, at: 0)
            updatedConversation.isRunning = updatedConversation.isRunning || olderState.isRunning
            updatedConversation.lastError = updatedConversation.lastError ?? olderState.lastError
            conversation = updatedConversation
            historyNextCursor = ConversationReducer.nextCursor(fromTurnsListResponse: value)
            isLoadingMoreHistory = false
        } catch {
            guard selectedThread?.id == threadID else { return }
            isLoadingMoreHistory = false
            if isMessageTooLong(error) {
                oversizedHistoryThreadIDs.insert(threadID)
                historyContentNotice = .olderContentOversized
                historyNextCursor = nil
                await reconnectTransportPreservingSelection(resumeThreadID: threadID)
                return
            }
            var updatedConversation = conversation
            updatedConversation.items.insert(
                ConversationItem(
                    id: UUID().uuidString,
                    kind: .error,
                    title: "无法加载更早历史",
                    body: error.localizedDescription
                ),
                at: 0
            )
            conversation = updatedConversation
        }
    }

    func setShouldLoadHistoryContent(_ enabled: Bool) {
        shouldLoadHistoryContent = enabled
        guard let thread = selectedThread else { return }
        if enabled, isConnected, !isDesignPreviewMode, conversation.items.isEmpty {
            Task { await select(thread) }
        } else if !enabled, !conversation.isRunning {
            conversation = ConversationState(threadID: thread.id)
            historyNextCursor = nil
            isLoadingHistoryContent = false
            isLoadingMoreHistory = false
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
        let observedClient = client
        eventTask = Task { @MainActor in
            for await event in observedClient.events {
                guard self.client === observedClient else { continue }
                // Filter out events that belong to a different thread so
                // a slow response from a previous thread can't corrupt
                // the current conversation.
                if let eventThreadID = event.threadID,
                   let currentThreadID = conversation.threadID,
                   eventThreadID != currentThreadID
                {
                    continue
                }
                var updatedConversation = conversation
                ConversationReducer.reduce(&updatedConversation, event: event)
                conversation = updatedConversation
                if case let .disconnected(message) = event {
                    if (isLoadingHistoryContent || isLoadingMoreHistory),
                       isMessageTooLongMessage(message)
                    {
                        continue
                    }
                    connectionState = classifyConnectionError(AppServerClientError.transport(message))
                } else if updatedConversation.isRunning {
                    connectionState = .running
                } else if case .running = connectionState {
                    connectionState = .connected
                }
            }
        }
    }

    private func handleOversizedHistory(thread: CodexThread) async {
        guard selectedThread?.id == thread.id else { return }
        oversizedHistoryThreadIDs.insert(thread.id)
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = .oversized
        conversation = ConversationState(threadID: thread.id)
        await reconnectTransportPreservingSelection(resumeThreadID: thread.id)
    }

    private func reconnectTransportPreservingSelection(resumeThreadID: String?) async {
        guard let payload = pairing ?? (try? credentialStore.load()) else {
            connectionState = .unpaired
            return
        }
        isDesignPreviewMode = false
        connectionState = .connecting
        eventTask?.cancel()
        client.disconnect(emitEvent: false)
        client = AppServerWebSocketClient()
        observeEvents()
        do {
            try await client.connect(to: payload, appVersion: appVersion)
            pairing = payload
            pairingText = payload.deepLinkURL.absoluteString
            connectionState = .connected
            try? await loadThreads()
            if let resumeThreadID, selectedThread?.id == resumeThreadID {
                let value = try await client.resumeThread(id: resumeThreadID)
                if selectedThread?.id == resumeThreadID,
                   let resumedThread = CodexThread.parseStartOrResumeResponse(value)
                {
                    selectedThread = resumedThread
                }
            }
        } catch {
            connectionState = classifyConnectionError(error)
        }
    }

    private func classifyConnectionError(_ error: Error) -> MobileConnectionState {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("401") ||
            message.localizedCaseInsensitiveContains("unauthorized")
        {
            return .tokenRejected
        }
        if message.localizedCaseInsensitiveContains("message too long") {
            return .disconnected("历史内容过大，WebSocket 已断开。请重连，或关闭“保留历史内容”后再打开该会话。")
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

    private func isMessageTooLong(_ error: Error) -> Bool {
        isMessageTooLongMessage(error.localizedDescription)
    }

    private func isMessageTooLongMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("message too long")
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
        store.connectionState = .preview
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
