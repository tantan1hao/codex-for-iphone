import CodexMobileKit
import Foundation
import SwiftUI
import UIKit

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
                .onAppear { applyThemeOverride(store.themePreference) }
                .onChange(of: store.themePreference) { _, newValue in
                    applyThemeOverride(newValue)
                }
        }
    }
}

@MainActor
private func applyThemeOverride(_ preference: ThemePreference) {
    let style: UIUserInterfaceStyle
    switch preference {
    case .system: style = .unspecified
    case .light: style = .light
    case .dark: style = .dark
    }
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
            window.overrideUserInterfaceStyle = style
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

enum UsageQuotaContentState: Equatable {
    case unsupported(message: String = "当前 Codex 连接尚未提供使用额度接口。")
    case loading
    case error(message: String, lastUpdated: String? = nil)
    case loaded(CodexUsageQuota, lastUpdated: String? = nil)
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
    @Published var activePane: WorkspacePane = .chat
    @Published var isScannerPresented = false
    @Published var isSidebarPresented = false
    @Published var isSettingsPresented = false
    @Published var presentedToolPane: WorkspacePane?
    @Published var themePreference: ThemePreference = ThemePreference(
        rawValue: UserDefaults.standard.string(forKey: CodexMobileStore.themePreferenceKey) ?? ThemePreference.system.rawValue
    ) ?? .system {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: Self.themePreferenceKey)
        }
    }
    @Published private(set) var isSendingComposer = false
    @Published private(set) var isInterruptingTurn = false
    @Published private(set) var answeringApprovalID: JSONRPCID?
    @Published private(set) var answeringApprovalDecisionID: String?
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
    @Published var selectedServiceTier = CodexServiceTier(
        rawValue: UserDefaults.standard.string(forKey: CodexMobileStore.serviceTierPreferenceKey) ?? ""
    ) ?? .standard {
        didSet {
            UserDefaults.standard.set(selectedServiceTier.rawValue, forKey: Self.serviceTierPreferenceKey)
        }
    }
    @Published var selectedPermissionPreset: CodexPermissionPreset = .workspaceWrite
    @Published var isPlanModeEnabled = false
    @Published private(set) var isRestoringSavedPairing = true
    @Published private(set) var collaborationModes: [CodexCollaborationMode] = []
    @Published private(set) var automationsState: AutomationsFeatureView.ContentState = .unsupported()
    @Published private(set) var contextUsageState: ContextUsageFeatureView.ContentState = .unsupported()
    @Published private(set) var usageQuotaState: UsageQuotaContentState = .unsupported()

    private static let historyContentPreferenceKey = "CodexMobile.shouldLoadHistoryContent"
    private static let themePreferenceKey = "CodexMobile.themePreference"
    private static let serviceTierPreferenceKey = "CodexMobile.serviceTier"
    private static let historyPageLimit = 1
    private static let selectedThreadSyncPageLimit = 3
    private let credentialStore = PairingCredentialStore()
    private var client = AppServerWebSocketClient()
    private var eventTask: Task<Void, Never>?
    private var threadListRefreshTask: Task<Void, Never>?
    private var threadContentRefreshTask: Task<Void, Never>?
    private var syncLoopTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var didAttemptRestore = false
    private var oversizedHistoryThreadIDs = Set<String>()
    private var latestTokenUsage: CodexTokenUsage?
    private var contextCompactStatus: ContextUsageFeatureView.CompactStatus = .unavailable("等待 Codex 返回上下文用量。")
    private var terminalActiveProcessID: String?
    private var terminalOutputContinuation: AsyncThrowingStream<TerminalCommandEvent, Error>.Continuation?

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var canReconnect: Bool {
        pairing != nil &&
            connectionState != .connecting &&
            connectionState != .running
    }

    var canSendComposer: Bool {
        isConnected &&
            !conversation.isRunning &&
            !isSendingComposer &&
            !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canInterruptTurn: Bool {
        isConnected && conversation.isRunning && selectedThread != nil && !isInterruptingTurn
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

    var availableServiceTiers: [CodexServiceTier] {
        serviceTiers(for: selectedModel)
    }

    var activeServiceTier: CodexServiceTier {
        availableServiceTiers.contains(selectedServiceTier) ? selectedServiceTier : .standard
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

    var serviceTierStatusTitle: String {
        activeServiceTier.displayTitle
    }

    var compactServiceTierStatusTitle: String {
        activeServiceTier.compactTitle
    }

    var planModeAvailable: Bool {
        planCollaborationMode != nil
    }

    private var planCollaborationMode: CodexCollaborationMode? {
        collaborationModes.first { mode in
            guard mode.isEnabled else { return false }
            let searchable = "\(mode.id) \(mode.title) \(mode.description ?? "")".lowercased()
            return searchable.contains("plan") || searchable.contains("计划")
        }
    }

    var contextRemainingTitle: String? {
        guard case let .loaded(snapshot) = contextUsageState,
              let fraction = snapshot.resolvedRemainingFraction
        else { return nil }
        return "\(Int((fraction * 100).rounded()))% context"
    }

    var isConnected: Bool {
        switch connectionState {
        case .connected, .running:
            true
        default:
            false
        }
    }

    var shouldShowWorkspace: Bool {
        pairing != nil || isConnected
    }

    func activatePane(_ pane: WorkspacePane) {
        activePane = pane
        isSidebarPresented = false
    }

    func presentToolPane(_ pane: WorkspacePane) {
        guard WorkspacePane.sheetPanes.contains(pane) else { return }
        presentedToolPane = pane
        isSidebarPresented = false
    }

    func setThemePreference(_ preference: ThemePreference) {
        themePreference = preference
    }

    func setPlanModeEnabled(_ enabled: Bool) {
        isPlanModeEnabled = enabled
    }

    func restoreAndConnectIfNeeded() async {
        guard !didAttemptRestore, pairing == nil else {
            isRestoringSavedPairing = false
            return
        }
        didAttemptRestore = true
        defer { isRestoringSavedPairing = false }
        do {
            guard let savedPairing = try credentialStore.load() else { return }
            pairing = savedPairing
            pairingText = savedPairing.deepLinkURL.absoluteString
            try await connect(savedPairing, persist: false)
        } catch is CancellationError {
            return
        } catch {
            connectionState = classifyConnectionError(error)
        }
    }

    func connectFromText() async {
        isRestoringSavedPairing = false
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
        isRestoringSavedPairing = false
        connectionState = .connecting
        pairing = payload
        pairingText = payload.deepLinkURL.absoluteString
        activePane = .chat
        presentedToolPane = nil
        threads = []
        selectedThread = nil
        conversation = ConversationState()
        composerText = ""
        isSendingComposer = false
        isInterruptingTurn = false
        isPlanModeEnabled = false
        automationsState = .unsupported()
        contextUsageState = .unsupported()
        usageQuotaState = .unsupported()
        latestTokenUsage = nil
        contextCompactStatus = .unavailable("等待 Codex 返回上下文用量。")
        terminalActiveProcessID = nil
        terminalOutputContinuation = nil
        answeringApprovalID = nil
        answeringApprovalDecisionID = nil
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = nil
        if persist {
            try? credentialStore.save(payload)
        }
        let (generation, connectionClient) = prepareClientForConnection()
        do {
            try await connectionClient.connect(to: payload, appVersion: appVersion)
            try ensureCurrentConnection(generation: generation, client: connectionClient)
            connectionState = .connected
            await refreshSessionConfiguration(cwd: payload.cwd, using: connectionClient, generation: generation)
            try ensureCurrentConnection(generation: generation, client: connectionClient)
            try await loadThreads(using: connectionClient, generation: generation)
            try ensureCurrentConnection(generation: generation, client: connectionClient)
            startSyncLoop()
        } catch {
            if !isCurrentConnection(generation: generation, client: connectionClient) {
                connectionClient.disconnect(emitEvent: false)
                throw CancellationError()
            }
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
        } catch is CancellationError {
            return
        } catch {
            connectionState = classifyConnectionError(error)
        }
    }

    func disconnect() {
        invalidateCurrentConnection(emitDisconnectEvent: true)
        selectedThread = nil
        conversation = ConversationState()
        activePane = .chat
        isSendingComposer = false
        isInterruptingTurn = false
        isPlanModeEnabled = false
        automationsState = .unsupported(message: "已断开连接。")
        usageQuotaState = .unsupported(message: "已断开连接。")
        latestTokenUsage = nil
        contextCompactStatus = .unavailable("已断开连接。")
        updateContextUsageState()
        terminalActiveProcessID = nil
        terminalOutputContinuation = nil
        answeringApprovalID = nil
        answeringApprovalDecisionID = nil
        isSettingsPresented = false
        presentedToolPane = nil
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
        isRestoringSavedPairing = false
        activePane = .chat
        presentedToolPane = nil
        threads = []
        selectedThread = nil
        conversation = ConversationState()
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        isInterruptingTurn = false
        isPlanModeEnabled = false
        automationsState = .unsupported()
        usageQuotaState = .unsupported()
        latestTokenUsage = nil
        contextCompactStatus = .unavailable("等待 Codex 返回上下文用量。")
        updateContextUsageState()
        terminalActiveProcessID = nil
        terminalOutputContinuation = nil
        answeringApprovalID = nil
        answeringApprovalDecisionID = nil
        historyNextCursor = nil
        historyContentNotice = nil
        connectionState = .unpaired
    }

    func loadThreads() async throws {
        try await loadThreads(using: client)
    }

    private func loadThreads(using loadingClient: AppServerWebSocketClient, generation: Int? = nil) async throws {
        let value = try await loadingClient.listThreads()
        if let generation {
            try ensureCurrentConnection(generation: generation, client: loadingClient)
        }
        let currentThreadID = selectedThread?.id
        let previousSelectedThread = selectedThread
        threads = CodexThread.parseListResponse(value)
        if let currentThreadID,
           let updatedThread = threads.first(where: { $0.id == currentThreadID })
        {
            selectedThread = updatedThread
            if selectedThreadNeedsContentRefresh(previous: previousSelectedThread, updated: updatedThread) {
                scheduleSelectedThreadContentRefresh()
            }
        } else if let selectedThread,
                  !threads.contains(where: { $0.id == selectedThread.id })
        {
            threads.insert(selectedThread, at: 0)
        }
    }

    func refreshThreads() async {
        guard isConnected else { return }
        do {
            try await loadThreads()
        } catch {
            // Sidebar refresh should not disrupt the active thread.
        }
    }

    func startNewThread() async {
        guard let pairing else { return }
        threadContentRefreshTask?.cancel()
        do {
            let value = try await client.startThread(cwd: pairing.cwd, settings: currentSessionSettings)
            guard let thread = CodexThread.parseStartOrResumeResponse(value) else { return }
            selectedThread = thread
            if !threads.contains(where: { $0.id == thread.id }) {
                threads.insert(thread, at: 0)
            }
            updateTokenUsage(from: value)
            sortThreads()
            conversation = ConversationState(threadID: thread.id)
            historyContentNotice = nil
            try? await loadThreads()
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func select(_ thread: CodexThread) async {
        threadContentRefreshTask?.cancel()
        selectedThread = thread
        conversation = ConversationState(threadID: thread.id)
        historyNextCursor = nil
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyContentNotice = nil
        guard isConnected else { return }
        if oversizedHistoryThreadIDs.contains(thread.id) {
            historyContentNotice = .oversized
            conversation = ConversationState(threadID: thread.id)
            return
        }
        if !shouldLoadHistoryContent {
            conversation = ConversationState(threadID: thread.id)
            return
        }
        do {
            let value = try await client.resumeThread(id: thread.id)
            // Only apply if the user hasn't already switched away
            guard selectedThread?.id == thread.id else { return }
            updateTokenUsage(from: value)
            if let resumedThread = CodexThread.parseStartOrResumeResponse(value) {
                selectedThread = mergeThread(existing: thread, incoming: resumedThread)
            } else {
                selectedThread = thread
            }
            isLoadingHistoryContent = true
            let turnsValue = try await client.listThreadTurns(threadID: thread.id, limit: Self.historyPageLimit)
            guard selectedThread?.id == thread.id, shouldLoadHistoryContent else { return }
            updateTokenUsage(from: turnsValue)
            conversation = ConversationReducer.state(fromTurnsListResponse: turnsValue, threadID: thread.id)
            historyNextCursor = ConversationReducer.nextCursor(fromTurnsListResponse: turnsValue)
            isLoadingHistoryContent = false
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
        let optimisticID = appendOptimisticUserMessage(threadID: threadID, text: text)
        conversation.isRunning = true
        composerText = ""
        do {
            connectionState = .running
            let cwd = selectedThread?.cwd.isEmpty == false ? selectedThread?.cwd ?? "" : pairing?.cwd ?? ""
            let value = try await client.startTurn(
                threadID: threadID,
                text: text,
                cwd: cwd,
                settings: currentSessionSettings,
                collaborationMode: isPlanModeEnabled ? planCollaborationMode : nil
            )
            updateTokenUsage(from: value)
            clearOptimisticStatus(id: optimisticID)
            scheduleThreadListRefresh()
            scheduleSelectedThreadContentRefresh(delay: .milliseconds(250), forceLatest: historyContentNotice == .oversized)
        } catch {
            removeOptimisticMessage(id: optimisticID)
            conversation.isRunning = false
            conversation.activeTurnID = nil
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
            conversation = ConversationReducer.prependingOlder(existing: conversation, older: olderState)
            historyNextCursor = ConversationReducer.nextCursor(fromTurnsListResponse: value)
            isLoadingMoreHistory = false
        } catch {
            guard selectedThread?.id == threadID else { return }
            isLoadingMoreHistory = false
            if isMessageTooLong(error) {
                oversizedHistoryThreadIDs.insert(threadID)
                historyContentNotice = .olderContentOversized
                historyNextCursor = nil
                await reconnectTransportPreservingSelection(resumeThreadID: nil)
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
        if enabled, isConnected, conversation.items.isEmpty {
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
        let previousServiceTier = selectedServiceTier
        selectedModelID = model.model
        if !model.supportedReasoningEfforts.isEmpty,
           !model.supportedReasoningEfforts.contains(selectedReasoningEffort)
        {
            selectedReasoningEffort = model.defaultReasoningEffort ?? model.supportedReasoningEfforts.first ?? selectedReasoningEffort
        }
        if !serviceTiers(for: model).contains(selectedServiceTier) {
            selectedServiceTier = .standard
        }
        await writeSessionSettings(
            edits: [
                ("model", .string(model.model)),
                ("model_reasoning_effort", .string(selectedReasoningEffort)),
            ],
            rollback: {
                self.selectedModelID = previous
                self.selectedReasoningEffort = previousEffort
                self.selectedServiceTier = previousServiceTier
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

    func changeServiceTier(to tier: CodexServiceTier) {
        guard canChangeSessionSettings, availableServiceTiers.contains(tier) else { return }
        selectedServiceTier = tier
    }

    func interrupt() async {
        guard canInterruptTurn, let threadID = selectedThread?.id else { return }
        isInterruptingTurn = true
        do {
            _ = try await client.interruptTurn(threadID: threadID, turnID: conversation.activeTurnID)
        } catch {
            isInterruptingTurn = false
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func answerApproval(_ option: ApprovalDecisionOption) async {
        guard let approval = conversation.activeApproval,
              approval.decisionOptions.contains(option),
              answeringApprovalID == nil
        else { return }
        answeringApprovalID = approval.id
        answeringApprovalDecisionID = option.id
        do {
            try await client.respondToServerRequest(id: approval.id, result: approval.response(decision: option))
            var updatedConversation = conversation
            updatedConversation.activeApproval = nil
            conversation = updatedConversation
            answeringApprovalID = nil
            answeringApprovalDecisionID = nil
        } catch {
            answeringApprovalID = nil
            answeringApprovalDecisionID = nil
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    func answerApproval(_ decision: String) async {
        guard let approval = conversation.activeApproval,
              let option = approval.decisionOptions.first(where: { $0.id == decision })
        else { return }
        await answerApproval(option)
    }

    private func appendOptimisticUserMessage(threadID: String, text: String) -> String {
        let id = "optimistic-user-\(UUID().uuidString)"
        if conversation.threadID != threadID {
            conversation = ConversationState(threadID: threadID)
        }
        conversation.items.append(
            ConversationItem(
                id: id,
                kind: .user,
                title: "You",
                body: text,
                status: "sending"
            )
        )
        conversation = ConversationReducer.normalized(conversation)
        return id
    }

    private func clearOptimisticStatus(id: String?) {
        guard let id,
              let index = conversation.items.firstIndex(where: { $0.id == id })
        else { return }
        conversation.items[index].status = nil
    }

    private func removeOptimisticMessage(id: String?) {
        guard let id else { return }
        conversation.items.removeAll { $0.id == id }
    }

    private func prepareClientForConnection() -> (generation: Int, client: AppServerWebSocketClient) {
        connectionGeneration += 1
        let generation = connectionGeneration
        eventTask?.cancel()
        threadListRefreshTask?.cancel()
        threadContentRefreshTask?.cancel()
        syncLoopTask?.cancel()
        client.disconnect(emitEvent: false)
        let connectionClient = AppServerWebSocketClient()
        client = connectionClient
        observeEvents(for: connectionClient, generation: generation)
        return (generation, connectionClient)
    }

    private func invalidateCurrentConnection(emitDisconnectEvent: Bool) {
        connectionGeneration += 1
        eventTask?.cancel()
        threadListRefreshTask?.cancel()
        threadContentRefreshTask?.cancel()
        syncLoopTask?.cancel()
        client.disconnect(emitEvent: emitDisconnectEvent)
    }

    private func isCurrentConnection(generation: Int, client observedClient: AppServerWebSocketClient) -> Bool {
        connectionGeneration == generation && self.client === observedClient
    }

    private func ensureCurrentConnection(generation: Int, client observedClient: AppServerWebSocketClient) throws {
        guard isCurrentConnection(generation: generation, client: observedClient) else {
            observedClient.disconnect(emitEvent: false)
            throw CancellationError()
        }
    }

    private func observeEvents(for observedClient: AppServerWebSocketClient, generation: Int) {
        eventTask?.cancel()
        eventTask = Task { @MainActor in
            for await event in observedClient.events {
                guard self.isCurrentConnection(generation: generation, client: observedClient) else {
                    observedClient.disconnect(emitEvent: false)
                    return
                }
                syncFeatureState(from: event)
                syncThreadMetadata(from: event)
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
                conversation = ConversationReducer.normalized(updatedConversation)
                updatePendingControls(after: event)
                if case let .disconnected(message) = event {
                    if (isLoadingHistoryContent || isLoadingMoreHistory),
                       isMessageTooLongMessage(message)
                    {
                        continue
                    }
                    if isMessageTooLongMessage(message) {
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

    private func updatePendingControls(after event: AppServerEvent) {
        switch event {
        case .disconnected:
            isInterruptingTurn = false
            answeringApprovalID = nil
            answeringApprovalDecisionID = nil
        case let .notification(method, _):
            if method == "turn/completed" {
                isInterruptingTurn = false
                answeringApprovalID = nil
                answeringApprovalDecisionID = nil
            } else if method == "serverRequest/resolved" {
                answeringApprovalID = nil
                answeringApprovalDecisionID = nil
            }
        case .serverRequest:
            break
        }
    }

    private func syncThreadMetadata(from event: AppServerEvent) {
        guard case let .notification(method, params) = event else { return }
        let object = params?.objectValue ?? [:]
        switch method {
        case "thread/started":
            if let thread = object["thread"].flatMap(CodexThread.parse) {
                upsertThread(thread)
            } else {
                scheduleThreadListRefresh()
            }
        case "thread/name/updated":
            guard let threadID = object["threadId"]?.stringValue else {
                scheduleThreadListRefresh()
                return
            }
            updateThread(id: threadID) { thread in
                thread.name = object["threadName"]?.stringValue
            }
            scheduleThreadListRefresh()
        case "thread/status/changed":
            guard let threadID = object["threadId"]?.stringValue else { return }
            updateThread(id: threadID) { thread in
                thread.status = object["status"]?.stringValue ?? thread.status
                thread.updatedAt = Date()
            }
            if threadID == selectedThread?.id,
               object["status"]?.stringValue != "running"
            {
                scheduleSelectedThreadContentRefresh(forceLatest: historyContentNotice == .oversized)
            }
        case "thread/archived":
            if let threadID = object["threadId"]?.stringValue {
                threads.removeAll { $0.id == threadID }
                if selectedThread?.id == threadID {
                    selectedThread = nil
                    conversation = ConversationState()
                }
            }
        case "thread/unarchived":
            scheduleThreadListRefresh()
        case "thread/closed":
            guard let threadID = object["threadId"]?.stringValue else { return }
            updateThread(id: threadID) { thread in
                thread.status = "notLoaded"
            }
        case "turn/started":
            if let threadID = event.threadID {
                updateThread(id: threadID) { thread in
                    thread.status = "running"
                    thread.updatedAt = Date()
                }
            }
        case "turn/completed":
            if let threadID = event.threadID {
                updateThread(id: threadID) { thread in
                    thread.status = "loaded"
                    thread.updatedAt = Date()
                }
                if threadID == selectedThread?.id {
                    scheduleSelectedThreadContentRefresh(forceLatest: historyContentNotice == .oversized)
                }
            }
            scheduleThreadListRefresh()
        default:
            break
        }
    }

    private func upsertThread(_ incoming: CodexThread) {
        if let index = threads.firstIndex(where: { $0.id == incoming.id }) {
            threads[index] = mergeThread(existing: threads[index], incoming: incoming)
        } else {
            threads.insert(incoming, at: 0)
        }
        if let selectedThread, selectedThread.id == incoming.id {
            self.selectedThread = mergeThread(existing: selectedThread, incoming: incoming)
        }
        sortThreads()
    }

    private func updateThread(id: String, _ update: (inout CodexThread) -> Void) {
        if let index = threads.firstIndex(where: { $0.id == id }) {
            update(&threads[index])
            if selectedThread?.id == id {
                selectedThread = threads[index]
            }
            sortThreads()
        } else {
            scheduleThreadListRefresh()
        }
    }

    private func mergeThread(existing: CodexThread, incoming: CodexThread) -> CodexThread {
        CodexThread(
            id: incoming.id,
            name: incoming.name ?? existing.name,
            preview: incoming.preview.isEmpty ? existing.preview : incoming.preview,
            cwd: incoming.cwd.isEmpty ? existing.cwd : incoming.cwd,
            status: incoming.status.isEmpty ? existing.status : incoming.status,
            updatedAt: incoming.updatedAt ?? existing.updatedAt
        )
    }

    private func sortThreads() {
        threads.sort { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?):
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.displayTitle.localizedCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }

    private func scheduleThreadListRefresh(delay: Duration = .milliseconds(800)) {
        threadListRefreshTask?.cancel()
        threadListRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
                guard self.isConnected else { return }
                try await self.loadThreads()
            } catch is CancellationError {
            } catch {
                // Metadata refresh is opportunistic; keep the active conversation intact.
            }
        }
    }

    private func startSyncLoop() {
        syncLoopTask?.cancel()
        syncLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                    guard self.isConnected else { continue }
                    try await self.loadThreads()
                    await self.refreshSelectedThreadContent()
                } catch is CancellationError {
                    return
                } catch {
                    // Polling is a fallback path; transient failures should not tear down the connection.
                }
            }
        }
    }

    private func scheduleSelectedThreadContentRefresh(
        delay: Duration = .milliseconds(600),
        forceLatest: Bool = false
    ) {
        threadContentRefreshTask?.cancel()
        threadContentRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
                await self.refreshSelectedThreadContent(forceLatest: forceLatest)
            } catch is CancellationError {
            } catch {
                // Content refresh is opportunistic; keep the current transcript intact.
            }
        }
    }

    private func refreshSelectedThreadContent(forceLatest: Bool = false) async {
        guard isConnected,
              shouldLoadHistoryContent,
              !conversation.isRunning,
              !isLoadingHistoryContent,
              !isLoadingMoreHistory,
              (forceLatest || historyContentNotice != .oversized),
              let threadID = selectedThread?.id
        else { return }

        do {
            let limit = forceLatest || historyContentNotice != nil ? 1 : Self.selectedThreadSyncPageLimit
            let value = try await client.listThreadTurns(threadID: threadID, limit: limit)
            guard selectedThread?.id == threadID else { return }
            updateTokenUsage(from: value)
            let refreshedState = ConversationReducer.state(fromTurnsListResponse: value, threadID: threadID)
            mergeConversation(refreshedState)
            if historyNextCursor == nil {
                historyNextCursor = ConversationReducer.nextCursor(fromTurnsListResponse: value)
            }
        } catch {
            guard selectedThread?.id == threadID else { return }
            if isMessageTooLong(error), let selectedThread {
                if historyContentNotice != nil {
                    await reconnectTransportPreservingSelection(resumeThreadID: nil)
                    return
                }
                await handleOversizedHistory(thread: selectedThread)
            }
        }
    }

    private func mergeConversation(_ incoming: ConversationState) {
        guard incoming.threadID == conversation.threadID else { return }
        conversation = ConversationReducer.merging(existing: conversation, incoming: incoming)
    }

    private func selectedThreadNeedsContentRefresh(previous: CodexThread?, updated: CodexThread) -> Bool {
        guard previous?.id == updated.id else { return false }
        guard let previousDate = previous?.updatedAt,
              let updatedDate = updated.updatedAt
        else { return false }
        return updatedDate.timeIntervalSince(previousDate) > 0.5
    }

    private func handleOversizedHistory(thread: CodexThread) async {
        guard selectedThread?.id == thread.id else { return }
        oversizedHistoryThreadIDs.insert(thread.id)
        isLoadingHistoryContent = false
        isLoadingMoreHistory = false
        historyNextCursor = nil
        historyContentNotice = .oversized
        conversation = ConversationState(threadID: thread.id)
        await reconnectTransportPreservingSelection(resumeThreadID: nil)
    }

    private func reconnectTransportPreservingSelection(resumeThreadID: String?) async {
        guard let payload = pairing ?? (try? credentialStore.load()) else {
            connectionState = .unpaired
            return
        }
        connectionState = .connecting
        let (generation, reconnectClient) = prepareClientForConnection()
        do {
            try await reconnectClient.connect(to: payload, appVersion: appVersion)
            try ensureCurrentConnection(generation: generation, client: reconnectClient)
            pairing = payload
            pairingText = payload.deepLinkURL.absoluteString
            connectionState = .connected
            do {
                try await loadThreads(using: reconnectClient, generation: generation)
            } catch {
                if error is CancellationError {
                    throw error
                }
            }
            try ensureCurrentConnection(generation: generation, client: reconnectClient)
            startSyncLoop()
            if let resumeThreadID, selectedThread?.id == resumeThreadID {
                let value = try await reconnectClient.resumeThread(id: resumeThreadID)
                try ensureCurrentConnection(generation: generation, client: reconnectClient)
                if selectedThread?.id == resumeThreadID,
                   let resumedThread = CodexThread.parseStartOrResumeResponse(value)
                {
                    selectedThread = mergeThread(existing: selectedThread ?? resumedThread, incoming: resumedThread)
                }
            }
        } catch is CancellationError {
            reconnectClient.disconnect(emitEvent: false)
        } catch {
            if isCurrentConnection(generation: generation, client: reconnectClient) {
                connectionState = classifyConnectionError(error)
            } else {
                reconnectClient.disconnect(emitEvent: false)
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
            permissionPreset: selectedPermissionPreset,
            serviceTier: activeServiceTier
        )
    }

    private func refreshSessionConfiguration(
        cwd: String,
        using configurationClient: AppServerWebSocketClient? = nil,
        generation: Int? = nil
    ) async {
        let activeClient = configurationClient ?? client
        func isStillCurrent() -> Bool {
            guard let generation else { return true }
            return isCurrentConnection(generation: generation, client: activeClient)
        }

        do {
            let modelValue = try await activeClient.listModels()
            guard isStillCurrent() else { return }
            let models = CodexModelOption.parseListResponse(modelValue)
            if !models.isEmpty {
                availableModels = models.filter { !$0.displayName.isEmpty }
            }
        } catch {
            guard isStillCurrent() else { return }
            availableModels = [.fallback]
        }

        do {
            let modes = try await activeClient.listCollaborationModes()
            guard isStillCurrent() else { return }
            collaborationModes = modes
        } catch {
            guard isStillCurrent() else { return }
            collaborationModes = []
            isPlanModeEnabled = false
        }

        do {
            let configValue = try await activeClient.readConfig(cwd: cwd)
            guard isStillCurrent() else { return }
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
            if let serviceTier = CodexServiceTier.fromConfig(
                config["serviceTier"]
                    ?? config["service_tier"]
                    ?? config["default_service_tier"]
                    ?? config["default-service-tier"]
            ) {
                selectedServiceTier = serviceTier
            }
            selectedPermissionPreset = CodexPermissionPreset.fromConfig(
                approvalPolicy: config["approval_policy"],
                sandboxMode: config["sandbox_mode"]
            )
        } catch {
            guard isStillCurrent() else { return }
            if let defaultModel = availableModels.first(where: \.isDefault) ?? availableModels.first {
                selectedModelID = defaultModel.model
                selectedReasoningEffort = defaultModel.defaultReasoningEffort ?? selectedReasoningEffort
            }
        }
    }

    private func writeSessionSettings(edits: [(String, JSONValue)], rollback: @escaping () -> Void) async {
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

    private func serviceTiers(for model: CodexModelOption) -> [CodexServiceTier] {
        let additionalTiers = Set(model.additionalSpeedTiers.map { $0.lowercased() })
        return additionalTiers.contains(CodexServiceTier.fast.rawValue) ? [.standard, .fast] : [.standard]
    }
}

extension CodexMobileStore: TerminalFeatureActionProviding, WorkspaceFileDataSource {
    var terminalFeatureActions: TerminalFeatureActions {
        TerminalFeatureActions(
            run: { [weak self] request in
                guard let self else { throw TerminalFeatureError.unsupported }
                return try await self.runTerminalCommand(request)
            },
            stop: { [weak self] in
                await self?.stopTerminalCommand()
            },
            listDirectory: { [weak self] path in
                guard let self else { throw TerminalFeatureError.unsupported }
                return try await self.listTerminalDirectory(path: path)
            },
            sendEOF: { [weak self] in
                await self?.sendTerminalEOF()
            }
        )
    }

    private func listTerminalDirectory(path: String) async throws -> [String] {
        guard isConnected else { throw TerminalFeatureError.unsupported }
        let entries = try await client.readDirectory(path: path, includeHidden: false)
        return entries.map(\.name)
    }

    private func sendTerminalEOF() async {
        guard let processID = terminalActiveProcessID, !processID.isEmpty else { return }
        _ = try? await client.writeCommand(processID: processID, text: "", closeStdin: true)
    }

    func refreshAutomations() async {
        guard isConnected else {
            automationsState = .unsupported(message: "请先连接 Codex app-server。")
            return
        }
        automationsState = .loading
        do {
            let tasks = try await client.listAutomationTasks()
            automationsState = .loaded(
                automations: tasks.map(automationViewModel),
                lastUpdated: formattedNow()
            )
        } catch {
            automationsState = unsupportedOrErrorState(error)
        }
    }

    func refreshContextUsage() async {
        guard isConnected else {
            contextUsageState = .unsupported(message: "请先连接 Codex app-server。")
            return
        }
        updateContextUsageState()
    }

    func refreshUsageQuota() async {
        guard isConnected else {
            usageQuotaState = .unsupported(message: "请先连接 Codex app-server。")
            return
        }
        usageQuotaState = .loading
        do {
            let quota = try await client.getUsageQuota()
            usageQuotaState = .loaded(quota, lastUpdated: formattedNow())
        } catch {
            usageQuotaState = usageQuotaUnsupportedOrErrorState(error)
        }
    }

    func requestContextCompact() async {
        guard isConnected, let threadID = selectedThread?.id else {
            contextCompactStatus = .unavailable("请先选择一个已连接的会话。")
            updateContextUsageState()
            return
        }
        contextCompactStatus = .compacting
        updateContextUsageState()
        do {
            _ = try await client.startCompact(threadID: threadID)
            contextCompactStatus = .compacted(message: "已请求压缩当前会话上下文。")
            updateContextUsageState()
        } catch {
            contextCompactStatus = .failed(error.localizedDescription)
            updateContextUsageState()
        }
    }

    func listDirectory(pairing: PairingPayload, relativePath: String) async throws -> WorkspaceDirectoryListing {
        guard isConnected else {
            throw WorkspaceFeatureError.notConnected
        }
        let sanitizedPath = sanitizedWorkspaceRelativePath(relativePath)
        let absolutePath = absoluteWorkspacePath(pairing: pairing, relativePath: sanitizedPath)
        let entries = try await client.readDirectory(path: absolutePath, includeHidden: false)
        return WorkspaceDirectoryListing(
            relativePath: sanitizedPath,
            entries: entries.map { workspaceEntry(from: $0, pairing: pairing, fallbackDirectory: sanitizedPath) }
        )
    }

    func loadFileData(pairing: PairingPayload, relativePath: String, byteLimit: Int) async throws -> Data {
        guard isConnected else {
            throw WorkspaceFeatureError.notConnected
        }
        let sanitizedPath = sanitizedWorkspaceRelativePath(relativePath)
        let absolutePath = absoluteWorkspacePath(pairing: pairing, relativePath: sanitizedPath)
        let content = try await client.readFile(path: absolutePath)
        if let size = content.size, size > byteLimit {
            throw WorkspaceFeatureError.fileTooLarge
        }
        guard let data = content.data ?? content.text.map({ Data($0.utf8) }) else {
            throw WorkspaceFeatureError.emptyFileContent
        }
        guard data.count <= byteLimit else {
            throw WorkspaceFeatureError.fileTooLarge
        }
        return data
    }

    private func runTerminalCommand(_ request: TerminalCommandRequest) async throws -> AsyncThrowingStream<TerminalCommandEvent, Error> {
        guard isConnected else {
            throw TerminalFeatureError.unsupported
        }

        let command = request.command
        let cwd = request.cwd.isEmpty ? pairing?.cwd : request.cwd
        return AsyncThrowingStream { continuation in
            terminalOutputContinuation = continuation
            Task { @MainActor in
                do {
                    let result = try await client.startCommand(
                        command: "/bin/sh",
                        cwd: cwd,
                        args: ["-lc", command],
                        timeoutSeconds: 120
                    )
                    if !result.processID.isEmpty {
                        terminalActiveProcessID = result.processID
                    }
                    if let output = result.output, !output.isEmpty {
                        continuation.yield(.stdout(output))
                    }
                    if let stderr = result.stderr, !stderr.isEmpty {
                        continuation.yield(.stderr(stderr))
                    }
                    if !result.status.localizedCaseInsensitiveContains("running") {
                        continuation.yield(.completed(exitCode: result.exitCode))
                        continuation.finish()
                        terminalActiveProcessID = nil
                        terminalOutputContinuation = nil
                    }
                } catch {
                    terminalActiveProcessID = nil
                    terminalOutputContinuation = nil
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func stopTerminalCommand() async {
        defer {
            terminalOutputContinuation?.yield(.completed(exitCode: nil))
            terminalOutputContinuation?.finish()
            terminalOutputContinuation = nil
            terminalActiveProcessID = nil
        }
        guard let processID = terminalActiveProcessID, !processID.isEmpty else { return }
        _ = try? await client.terminateCommand(processID: processID)
    }

    func syncFeatureState(from event: AppServerEvent) {
        switch event {
        case let .notification(method, params):
            updateTokenUsage(from: params, threadID: event.threadID)
            switch method {
            case "thread/tokenUsage/updated":
                break
            case "account/rateLimits/updated":
                updateUsageQuotaState(from: params)
            case "thread/compacted":
                contextCompactStatus = .compacted(message: "当前会话上下文已压缩。")
                updateContextUsageState()
            case "command/exec/outputDelta":
                guard let continuation = terminalOutputContinuation,
                      let delta = CodexCommandOutputDelta.parse(params ?? .null)
                else { return }
                continuation.yield(terminalEvent(from: delta))
                if delta.isFinal {
                    continuation.yield(.completed(exitCode: nil))
                    continuation.finish()
                    terminalOutputContinuation = nil
                    terminalActiveProcessID = nil
                }
            default:
                break
            }
        case let .disconnected(message):
            terminalOutputContinuation?.finish(throwing: AppServerClientError.transport(message))
            terminalOutputContinuation = nil
            terminalActiveProcessID = nil
        case .serverRequest:
            break
        }
    }

    func updateContextUsageState() {
        guard let latestTokenUsage else {
            contextUsageState = .unsupported(message: "等待 Codex 推送上下文用量；发送或恢复会话后会更新。")
            return
        }
        contextUsageState = .loaded(
            ContextUsageFeatureView.Snapshot(
                remainingFraction: latestTokenUsage.percentRemaining.map { $0 / 100 },
                tokensInContext: latestTokenUsage.totalTokens,
                contextWindow: latestTokenUsage.tokenLimit,
                compactStatus: contextCompactStatus,
                lastUpdated: formattedNow()
            )
        )
    }

    private func updateTokenUsage(from value: JSONValue?, threadID: String? = nil) {
        if let threadID,
           let selectedThreadID = selectedThread?.id,
           threadID != selectedThreadID
        {
            return
        }
        guard let value,
              let usage = CodexTokenUsage.find(in: value)
        else { return }
        latestTokenUsage = usage
        contextCompactStatus = compactStatus(for: usage)
        updateContextUsageState()
    }

    private func updateUsageQuotaState(from value: JSONValue?) {
        guard let value,
              let quota = CodexUsageQuota.parse(value)
        else { return }
        usageQuotaState = .loaded(quota, lastUpdated: formattedNow())
    }

    private func compactStatus(for usage: CodexTokenUsage) -> ContextUsageFeatureView.CompactStatus {
        guard let percentRemaining = usage.percentRemaining else {
            return .available
        }
        return percentRemaining < 25 ? .available : .notNeeded
    }

    private func terminalEvent(from delta: CodexCommandOutputDelta) -> TerminalCommandEvent {
        let stream = delta.stream.lowercased()
        if stream.contains("err") || stream == "2" {
            return .stderr(delta.text)
        }
        if stream.contains("interaction") || stream.contains("stdin") {
            return .interaction(delta.text)
        }
        return .stdout(delta.text)
    }

    private func unsupportedOrErrorState(_ error: Error) -> AutomationsFeatureView.ContentState {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("method") ||
            message.localizedCaseInsensitiveContains("not found") ||
            message.localizedCaseInsensitiveContains("unknown") ||
            message.localizedCaseInsensitiveContains("unsupported")
        {
            return .unsupported(message: "当前 Codex app-server 不支持自动化列表接口。")
        }
        return .error(message: message, lastUpdated: formattedNow())
    }

    private func usageQuotaUnsupportedOrErrorState(_ error: Error) -> UsageQuotaContentState {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("method") ||
            message.localizedCaseInsensitiveContains("not found") ||
            message.localizedCaseInsensitiveContains("unknown") ||
            message.localizedCaseInsensitiveContains("unsupported")
        {
            return .unsupported(message: "当前 Codex app-server 不支持使用额度接口。")
        }
        return .error(message: message, lastUpdated: formattedNow())
    }

    private func automationViewModel(_ task: CodexAutomationTaskSummary) -> AutomationsFeatureView.Automation {
        AutomationsFeatureView.Automation(
            id: task.id,
            title: task.title.isEmpty ? "未命名自动化" : task.title,
            subtitle: task.prompt,
            status: automationStatus(task.status, isEnabled: task.isEnabled),
            scheduleDescription: task.schedule,
            nextRunDescription: task.nextRunAt?.formatted(date: .abbreviated, time: .shortened),
            lastRunDescription: task.lastRunAt?.formatted(date: .abbreviated, time: .shortened),
            detail: AutomationsFeatureView.Detail(
                triggerDescription: task.schedule,
                prompt: task.prompt,
                targetDescription: automationTargetDescription(task),
                metadata: automationMetadataRows(task)
            )
        )
    }

    private func automationTargetDescription(_ task: CodexAutomationTaskSummary) -> String? {
        guard let object = task.raw.objectValue else { return nil }
        for key in ["destination", "target", "workspace", "project"] {
            guard let value = object[key] else { continue }
            if let string = value.stringValue, !string.isEmpty {
                return string
            }
            if let nested = value.objectValue {
                let candidates = ["name", "title", "path", "cwd", "id"]
                for candidate in candidates {
                    if let string = nested[candidate]?.stringValue, !string.isEmpty {
                        return string
                    }
                }
            }
        }
        return nil
    }

    private func automationStatus(_ status: String, isEnabled: Bool?) -> AutomationsFeatureView.AutomationStatus {
        if isEnabled == false { return .disabled }
        switch status.lowercased() {
        case "active", "enabled", "running", "scheduled":
            return .active
        case "paused":
            return .paused
        case "disabled":
            return .disabled
        case "failed", "error":
            return .failed
        default:
            return .unknown(status)
        }
    }

    private func automationMetadataRows(_ task: CodexAutomationTaskSummary) -> [AutomationsFeatureView.MetadataRow] {
        var rows: [AutomationsFeatureView.MetadataRow] = [
            .init(label: "ID", value: task.id),
            .init(label: "状态", value: task.status),
        ]
        if let createdAt = task.createdAt {
            rows.append(.init(label: "创建", value: createdAt.formatted(date: .abbreviated, time: .shortened)))
        }
        if let updatedAt = task.updatedAt {
            rows.append(.init(label: "更新", value: updatedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }

    private func workspaceEntry(
        from remote: CodexRemoteFileEntry,
        pairing: PairingPayload,
        fallbackDirectory: String
    ) -> WorkspaceFileEntry {
        let fallbackPath = appendWorkspacePath(remote.name, to: fallbackDirectory)
        let relativePath = relativeWorkspacePath(
            from: remote.path,
            cwd: pairing.cwd,
            fallback: fallbackPath
        )
        return WorkspaceFileEntry(
            name: remote.name.isEmpty ? URL(fileURLWithPath: remote.path).lastPathComponent : remote.name,
            relativePath: relativePath,
            kind: remote.isDirectory ? .directory : .file,
            byteCount: remote.size.map(Int64.init),
            modifiedAt: remote.modifiedAt
        )
    }

    private func absoluteWorkspacePath(pairing: PairingPayload, relativePath: String) -> String {
        let root = normalizedAbsolutePath(pairing.cwd)
        let relative = sanitizedWorkspaceRelativePath(relativePath)
        return relative.isEmpty ? root : "\(root)/\(relative)"
    }

    private func relativeWorkspacePath(from path: String, cwd: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sanitizedWorkspaceRelativePath(fallback) }
        guard trimmed.hasPrefix("/") else { return sanitizedWorkspaceRelativePath(trimmed) }

        let absolute = normalizedAbsolutePath(trimmed)
        let root = normalizedAbsolutePath(cwd)
        if absolute == root { return "" }
        if absolute.hasPrefix(root + "/") {
            return sanitizedWorkspaceRelativePath(String(absolute.dropFirst(root.count + 1)))
        }
        return sanitizedWorkspaceRelativePath(fallback)
    }

    private func appendWorkspacePath(_ component: String, to path: String) -> String {
        sanitizedWorkspaceRelativePath((path.isEmpty ? "" : "\(path)/") + component)
    }

    private func sanitizedWorkspaceRelativePath(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for rawComponent in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

    private func normalizedAbsolutePath(_ path: String) -> String {
        let sanitized = sanitizedWorkspaceRelativePath(path)
        return sanitized.isEmpty ? "/" : "/" + sanitized
    }

    func formattedNow() -> String {
        Date().formatted(date: .omitted, time: .shortened)
    }
}

private enum WorkspaceFeatureError: LocalizedError {
    case notConnected
    case fileTooLarge
    case emptyFileContent

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "请先连接 Codex app-server。"
        case .fileTooLarge:
            "文件超过当前预览大小限制。"
        case .emptyFileContent:
            "Codex app-server 未返回可预览的文件内容。"
        }
    }
}

extension CodexMobileStore {
    static func preview() -> CodexMobileStore {
        let store = CodexMobileStore()
        store.connectionState = .connected
        store.isRestoringSavedPairing = false
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
                additionalSpeedTiers: ["fast"],
                isDefault: true
            ),
            CodexModelOption(
                id: "gpt-5.4",
                model: "gpt-5.4",
                displayName: "GPT-5.4",
                defaultReasoningEffort: "high",
                supportedReasoningEfforts: ["medium", "high", "xhigh"],
                additionalSpeedTiers: ["fast"]
            ),
        ]
        store.selectedModelID = "gpt-5.5"
        store.selectedReasoningEffort = "xhigh"
        store.selectedServiceTier = .fast
        store.selectedPermissionPreset = .fullAccess
        return store
    }
}
