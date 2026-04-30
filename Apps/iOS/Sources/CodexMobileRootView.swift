import CodexMobileKit
import SwiftUI
import UIKit

struct CodexMobileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                CompactCodexRoot()
            } else {
                RegularCodexRoot()
            }
        }
        .preferredColorScheme(store.themePreference.colorScheme)
        .sheet(isPresented: $store.isScannerPresented) {
            QRScannerSheet { value in
                store.pairingText = value
                store.isScannerPresented = false
                Task { await store.connectFromText() }
            }
        }
        .sheet(isPresented: $store.isSettingsPresented) {
            SettingsView()
                .presentationDetents([.medium, .large])
        }
    }
}

struct RegularCodexRoot: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        HStack(spacing: 0) {
            CodexSidebar()
                .frame(width: 310)
            Rectangle()
                .fill(CodexTheme.separator)
                .frame(width: 1)
            WorkspacePaneContentView()
        }
        .background(CodexTheme.appBackground)
    }
}

struct CompactCodexRoot: View {
    @EnvironmentObject private var store: CodexMobileStore
    @GestureState private var sidebarDragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * 0.86, 336)
            let progress = sidebarProgress(drawerWidth: drawerWidth)
            ZStack(alignment: .leading) {
                NavigationStack {
                    WorkspacePaneContentView()
                }
                .background(CodexTheme.appBackground)

                if progress > 0 {
                    Color.black.opacity(0.48 * progress)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            store.isSidebarPresented = false
                        }

                    CompactSidebarDrawer(width: drawerWidth)
                        .offset(x: sidebarOffset(drawerWidth: drawerWidth))
                        .simultaneousGesture(sidebarDragGesture(drawerWidth: drawerWidth))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }

                if !store.isSidebarPresented {
                    HStack {
                        SidebarEdgeSwipeHandle(isPresented: $store.isSidebarPresented)
                            .frame(width: 22)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(2)
                }
            }
            .animation(.snappy(duration: 0.24), value: store.isSidebarPresented)
        }
    }

    private func sidebarProgress(drawerWidth: CGFloat) -> CGFloat {
        if store.isSidebarPresented {
            return max(0, min(1, 1 + sidebarDragTranslation / drawerWidth))
        }
        return max(0, min(1, sidebarDragTranslation / drawerWidth))
    }

    private func sidebarOffset(drawerWidth: CGFloat) -> CGFloat {
        if store.isSidebarPresented {
            return min(0, max(-drawerWidth, sidebarDragTranslation))
        }
        return min(0, -drawerWidth + sidebarDragTranslation)
    }

    private func sidebarDragGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($sidebarDragTranslation) { value, state, _ in
                if store.isSidebarPresented {
                    state = min(0, max(-drawerWidth, value.translation.width))
                } else if value.startLocation.x <= 28, value.translation.width > 0 {
                    state = min(drawerWidth, value.translation.width)
                }
            }
            .onEnded { value in
                if store.isSidebarPresented {
                    let shouldClose = value.translation.width < -drawerWidth * 0.24 ||
                        value.predictedEndTranslation.width < -drawerWidth * 0.38
                    if shouldClose {
                        store.isSidebarPresented = false
                    }
                } else {
                    let shouldOpen = value.startLocation.x <= 28 && (
                        value.translation.width > drawerWidth * 0.24 ||
                            value.predictedEndTranslation.width > drawerWidth * 0.44
                    )
                    if shouldOpen {
                        store.isSidebarPresented = true
                    }
                }
            }
    }
}

struct WorkspacePaneContentView: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        switch store.activePane {
        case .chat:
            ChatPaneContentView()
        case .automations:
            WorkspacePaneFeatureContainer(pane: .automations) {
                AutomationsFeatureView(
                    state: store.automationsState,
                    onRefresh: { await store.refreshAutomations() }
                )
                .task {
                    await store.refreshAutomations()
                }
            }
        case .terminal:
            WorkspacePaneFeatureContainer(pane: .terminal) {
                TerminalFeatureView(actions: store.terminalFeatureActions)
            }
        case .files:
            WorkspacePaneFeatureContainer(pane: .files) {
                FilesFeatureView(dataSource: store)
            }
        case .context:
            WorkspacePaneFeatureContainer(pane: .context) {
                ContextUsageFeatureView(
                    state: store.contextUsageState,
                    onRefresh: { await store.refreshContextUsage() },
                    onRequestCompact: { await store.requestContextCompact() }
                )
                .task {
                    await store.refreshContextUsage()
                }
            }
        }
    }
}

private struct ChatPaneContentView: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        if store.pairing == nil {
            PairingView()
        } else {
            CodexWorkspaceView()
        }
    }
}

private struct WorkspacePanePlaceholder: View {
    var pane: WorkspacePane

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePaneHeader(pane: pane)
            VStack(spacing: 18) {
                Image(systemName: pane.symbolName)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(CodexTheme.blue)
                    .frame(width: 72, height: 72)
                    .background(CodexTheme.selected, in: RoundedRectangle(cornerRadius: 18))
                VStack(spacing: 7) {
                    Text(pane.title)
                        .font(.title2.bold())
                        .foregroundStyle(CodexTheme.text)
                    Text("等待主功能接线")
                        .font(.body)
                        .foregroundStyle(CodexTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .background(CodexTheme.appBackground)
        .navigationTitle(pane.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkspacePaneFeatureContainer<Content: View>: View {
    var pane: WorkspacePane
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePaneHeader(pane: pane)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CodexTheme.appBackground)
        .navigationTitle(pane.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WorkspacePaneHeader: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore
    var pane: WorkspacePane

    var body: some View {
        HStack(spacing: 12) {
            if horizontalSizeClass == .compact {
                Button {
                    store.isSidebarPresented = true
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 34, height: 34)
                }
            }
            Image(systemName: pane.symbolName)
                .frame(width: 22)
            Text(pane.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
            if horizontalSizeClass != .compact {
                Text(store.pairing?.name ?? "mac")
                    .font(.headline)
                    .foregroundStyle(CodexTheme.tertiaryText)
            }
            Spacer(minLength: 8)
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CodexTheme.secondaryText)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(CodexTheme.appBackground)
    }
}

private struct SidebarEdgeSwipeHandle: UIViewRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let recognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isPresented = $isPresented
    }

    final class Coordinator: NSObject {
        var isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        @MainActor
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard !isPresented.wrappedValue, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            if recognizer.state == .ended,
               translation.x > 56 || velocity.x > 420
            {
                isPresented.wrappedValue = true
            }
        }
    }
}

struct CodexSidebar: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarTopChrome
            sidebarActions
            toolsSection
            projectHeader
            threadList
            Spacer(minLength: 16)
            settingsRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [CodexTheme.sidebarTop, CodexTheme.sidebarBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .task {
            await store.refreshThreads()
        }
    }

    private var sidebarTopChrome: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 12, height: 12)
            Circle().fill(.yellow).frame(width: 12, height: 12)
            Circle().fill(.green).frame(width: 12, height: 12)
            Spacer()
            Image(systemName: "sidebar.left")
                .foregroundStyle(CodexTheme.secondaryText)
        }
        .padding(.bottom, 24)
    }

    private var sidebarActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarAction(icon: "square.and.pencil", title: "新对话") {
                store.activatePane(.chat)
                Task { await store.startNewThread() }
            }
            .disabled(!store.canStartThread)
            .opacity(store.canStartThread ? 1 : 0.45)
        }
        .padding(.bottom, 22)
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工具")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CodexTheme.tertiaryText)
                .padding(.horizontal, 12)
            ForEach(WorkspacePane.allCases) { pane in
                Button {
                    store.activatePane(pane)
                } label: {
                    SidebarPaneRow(
                        pane: pane,
                        isSelected: store.activePane == pane
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 24)
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("项目")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CodexTheme.tertiaryText)
            }
            .font(.caption)
            .foregroundStyle(CodexTheme.tertiaryText)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(store.pairing?.name ?? "mac")
            }
            .foregroundStyle(CodexTheme.secondaryText)
            .font(.callout.weight(.semibold))
        }
        .padding(.bottom, 8)
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(store.threads) { thread in
                    Button {
                        store.activatePane(.chat)
                        Task { await store.select(thread) }
                    } label: {
                        SidebarThreadRow(
                            thread: thread,
                            isSelected: store.activePane == .chat && store.selectedThread?.id == thread.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var settingsRow: some View {
        Button {
            store.isSidebarPresented = false
            store.isSettingsPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                Text("设置")
                Spacer()
                connectionDot
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(CodexTheme.text)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var connectionDot: some View {
        Circle()
            .fill(store.connectionState.tint)
            .frame(width: 8, height: 8)
    }
}

struct SidebarAction: View {
    var icon: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(CodexTheme.text)
        }
        .buttonStyle(.plain)
    }
}

struct SidebarPaneRow: View {
    var pane: WorkspacePane
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.symbolName)
                .frame(width: 18)
            Text(pane.title)
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(isSelected ? CodexTheme.text : CodexTheme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? CodexTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarThreadRow: View {
    var thread: CodexThread
    var isSelected: Bool

    var body: some View {
        HStack {
            Text(thread.displayTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
                .lineLimit(1)
            Spacer()
            Text(relativeTime)
                .font(.callout.weight(.medium))
                .foregroundStyle(CodexTheme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? CodexTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var relativeTime: String {
        guard let date = thread.updatedAt else { return "" }
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 3600 { return "\(max(1, Int(interval / 60))) 分" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时" }
        return "\(Int(interval / 86_400)) 天"
    }
}

struct CompactThreadListView: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CodexTheme.sidebarTop, CodexTheme.sidebarBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    compactDrawerHeader
                    ConnectionStatusCard()
                    Button {
                        store.activatePane(.chat)
                        Task {
                            await store.startNewThread()
                            await MainActor.run {
                                store.isSidebarPresented = false
                            }
                        }
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(CodexDarkButtonStyle())
                    .disabled(!store.canStartThread)
                    .opacity(store.canStartThread ? 1 : 0.45)
                    compactToolsSection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("项目")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CodexTheme.tertiaryText)
                        ForEach(store.threads) { thread in
                            Button {
                                store.activatePane(.chat)
                                Task {
                                    await store.select(thread)
                                }
                            } label: {
                                SidebarThreadRow(
                                    thread: thread,
                                    isSelected: store.activePane == .chat && store.selectedThread?.id == thread.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
            }
        }
        .task {
            await store.refreshThreads()
        }
    }

    private var compactToolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工具")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CodexTheme.tertiaryText)
                .padding(.horizontal, 12)
            ForEach(WorkspacePane.allCases) { pane in
                Button {
                    store.activatePane(pane)
                } label: {
                    SidebarPaneRow(
                        pane: pane,
                        isSelected: store.activePane == pane
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var compactDrawerHeader: some View {
        HStack {
            Text("Codex")
                .font(.largeTitle.bold())
                .foregroundStyle(CodexTheme.text)
            Spacer()
            Button {
                store.isSidebarPresented = false
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexTheme.secondaryText)
            Button {
                store.isSidebarPresented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexTheme.secondaryText)
        }
        .padding(.top, 34)
    }
}

struct CompactSidebarDrawer: View {
    var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let drawerHeight = max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 20)
            CompactThreadListView()
                .frame(width: width, height: drawerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.leading, 10)
                .padding(.top, proxy.safeAreaInsets.top + 10)
                .padding(.bottom, proxy.safeAreaInsets.bottom + 10)
                .shadow(color: .black.opacity(0.34), radius: 22, x: 8, y: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea()
    }
}

struct PairingView: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        ZStack {
            CodexTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer(minLength: 24)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(CodexTheme.blue)
                VStack(spacing: 8) {
                    Text("连接 Mac 上的 Codex")
                        .font(.largeTitle.bold())
                        .foregroundStyle(CodexTheme.text)
                    Text("扫描 Codex Mobile Helper 的二维码，或粘贴配对链接。")
                        .font(.body)
                        .foregroundStyle(CodexTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                pairingEditor
                Spacer(minLength: 24)
            }
            .padding()
        }
        .navigationTitle("Pair")
    }

    private var pairingEditor: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.pairingText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(CodexTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                if store.pairingText.isEmpty {
                    Text("codex-mobile://pair?v=1&name=...")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(CodexTheme.tertiaryText)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 138)
            .background(CodexTheme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(CodexTheme.separator, lineWidth: 1)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    scanButton
                    connectButton
                    previewButton
                }
                VStack(spacing: 10) {
                    HStack {
                        scanButton
                        connectButton
                    }
                    previewButton
                }
            }
        }
        .frame(maxWidth: 560)
    }

    private var scanButton: some View {
        Button {
            store.isScannerPresented = true
        } label: {
            Label("扫描", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(CodexDarkButtonStyle())
    }

    private var connectButton: some View {
        Button {
            Task { await store.connectFromText() }
        } label: {
            Label("连接", systemImage: "waveform.path.ecg")
        }
        .buttonStyle(CodexPrimaryButtonStyle())
    }

    private var previewButton: some View {
        Button {
            store.loadDesignPreview()
        } label: {
            Label("查看界面预览", systemImage: "rectangle.split.2x1")
        }
        .buttonStyle(CodexDarkButtonStyle())
    }
}

struct CodexWorkspaceView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore
    private let bottomAnchorID = "conversation-bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 22) {
                        if store.selectedThread == nil {
                            EmptyDarkWorkspace()
                        } else {
                            changeSummaryIfNeeded
                            historyStatusIfNeeded
                            ForEach(store.conversation.items) { item in
                                ConversationItemView(item: item)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, conversationBottomPadding)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(CodexTheme.appBackground)
                .onAppear {
                    scrollToBottom(scrollProxy, animated: false)
                }
                .onChange(of: store.selectedThread?.id) { _, _ in
                    scrollToBottom(scrollProxy, animated: false)
                }
                .onChange(of: transcriptScrollKey) { _, _ in
                    scrollToBottom(scrollProxy)
                }
            }
            activeApprovalCard
            ComposerView()
        }
        .background(CodexTheme.appBackground)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var transcriptScrollKey: String {
        let items = store.conversation.items.map { item in
            "\(item.id):\(item.body.count):\(item.status ?? "")"
        }
        return "\(store.conversation.threadID ?? "")|\(items.joined(separator: "|"))|\(store.conversation.activeApproval?.id.description ?? "")"
    }

    private var conversationBottomPadding: CGFloat {
        store.conversation.activeApproval == nil ? 170 : 300
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy(duration: 0.22)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var changeSummaryIfNeeded: some View {
        if store.conversation.items.contains(where: { $0.kind == .fileChange }) {
            CodexChangeSummaryView()
        }
    }

    @ViewBuilder
    private var activeApprovalCard: some View {
        if let approval = store.conversation.activeApproval {
            ApprovalCard(approval: approval)
                .frame(maxWidth: 900)
                .padding(.horizontal, horizontalSizeClass == .compact ? 20 : 24)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(CodexTheme.appBackground)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var historyStatusIfNeeded: some View {
        if store.isLoadingHistoryContent {
            HistoryStatusCard(
                icon: "clock.arrow.circlepath",
                title: "正在加载最近历史",
                detail: "正在按最小分页读取旧消息，避免大历史会话断开连接。",
                isLoading: true
            )
        } else if let notice = store.historyContentNotice {
            HistoryStatusCard(
                icon: notice.icon,
                title: notice.title,
                detail: notice.detail,
                isLoading: false
            )
        } else if store.shouldShowHistoryDisabledNotice {
            HistoryStatusCard(
                icon: "clock.badge.xmark",
                title: "历史内容未加载",
                detail: "后续消息会从这里显示。",
                isLoading: false
            )
        }
        if store.canLoadMoreHistory || store.isLoadingMoreHistory {
            LoadMoreHistoryButton()
        }
    }
}

struct WorkspaceHeader: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        HStack(spacing: 12) {
            if horizontalSizeClass == .compact {
                compactHeader
            } else {
                regularHeader
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CodexTheme.secondaryText)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(CodexTheme.appBackground)
    }

    private var compactHeader: some View {
        Group {
            Button {
                store.isSidebarPresented = true
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 34, height: 34)
            }
            Text(store.selectedThread?.displayTitle ?? "查看 Codex 项目")
                .font(.headline.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
                .lineLimit(1)
            if store.isPreviewMode {
                previewBadge
            }
            if let contextRemainingTitle = store.contextRemainingTitle {
                contextBadge(contextRemainingTitle)
            }
            Spacer(minLength: 8)
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
        }
    }

    private var regularHeader: some View {
        Group {
            Text(store.selectedThread?.displayTitle ?? "查看 Codex 项目")
                .font(.headline.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
                .lineLimit(1)
            Text(store.pairing?.name ?? "mac")
                .font(.headline)
                .foregroundStyle(CodexTheme.tertiaryText)
            if store.isPreviewMode {
                previewBadge
            }
            if let contextRemainingTitle = store.contextRemainingTitle {
                contextBadge(contextRemainingTitle)
            }
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
            Spacer()
        }
    }

    private var previewBadge: some View {
        Text("预览")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.16), in: Capsule())
    }

    private func contextBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(CodexTheme.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(CodexTheme.blue.opacity(0.14), in: Capsule())
    }
}

struct EmptyDarkWorkspace: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(CodexTheme.secondaryText)
            Text("选择或新建一个 Codex 对话")
                .font(.title2.bold())
                .foregroundStyle(CodexTheme.text)
            Text("手机端默认收起侧边栏，点左上角按钮打开项目和对话列表。")
                .font(.body)
                .foregroundStyle(CodexTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                store.isSidebarPresented = true
            } label: {
                Label("打开侧边栏", systemImage: "sidebar.left")
            }
            .buttonStyle(CodexPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

struct CodexChangeSummaryView: View {
    private let rows: [ChangeRow] = [
        .init(path: ".../CodexMobileKit/AppServerCommandBuilder.swift", additions: 94),
        .init(path: ".../CodexMobileKit/AppServerWebSocketClient.swift", additions: 201),
        .init(path: "CodexMobileKit/CodexModels.swift", additions: 303),
        .init(path: "CodexMobileKit/JSONRPC.swift", additions: 107),
        .init(path: "CodexMobileKit/JSONValue.swift", additions: 106),
        .init(path: "CodexMobileKit/NetworkIdentity.swift", additions: 48),
        .init(path: "CodexMobileKit/PairingPayload.swift", additions: 112),
        .init(path: "CodexMobile/README.md", additions: 30),
        .init(path: "CodexMobile/project.yml", additions: 98),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.path)
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .foregroundStyle(CodexTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text("+\(row.additions)")
                        .foregroundStyle(CodexTheme.green)
                    Text("-0")
                        .foregroundStyle(.red)
                    Circle()
                        .fill(CodexTheme.blue)
                        .frame(width: 6, height: 6)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                if row.id != rows.last?.id {
                    Divider().overlay(CodexTheme.separator)
                }
            }
        }
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }

    private struct ChangeRow: Identifiable, Equatable {
        let id = UUID()
        var path: String
        var additions: Int
    }
}

struct ConnectionStatusCard: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.connectionState.tint)
                    .frame(width: 9, height: 9)
                Text(store.connectionState.title)
                    .font(.headline)
                    .foregroundStyle(CodexTheme.text)
                Spacer()
            }
            Text(store.connectionState.detail)
                .font(.caption)
                .foregroundStyle(CodexTheme.secondaryText)
            if let pairing = store.pairing {
                Text("\(pairing.name)  \(pairing.connectionTargetDescription)")
                    .font(.caption.monospaced())
                    .foregroundStyle(CodexTheme.tertiaryText)
                    .lineLimit(2)
                Text(connectionModeText(for: pairing))
                    .font(.caption)
                    .foregroundStyle(pairing.connectionPlan.canRunWithoutDesktopAppChanges ? CodexTheme.secondaryText : CodexTheme.orange)
                    .lineLimit(2)
                connectionActions
            } else {
                Button {
                    store.isScannerPresented = true
                } label: {
                    Label("配对", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(CodexDarkButtonStyle())
            }
        }
        .padding(12)
        .background(CodexTheme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.reconnect() }
            } label: {
                Label("重连", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CodexDarkButtonStyle())
            .disabled(!store.canReconnect)

            Button {
                store.disconnect()
            } label: {
                Label("断开", systemImage: "power")
            }
            .buttonStyle(CodexDarkButtonStyle())
            .disabled(!store.isConnected)
        }
    }

    private func connectionModeText(for pairing: PairingPayload) -> String {
        return switch pairing.connectionPlan.transport {
        case .helperLAN:
            "Helper LAN：不改桌面 Codex，Mac Helper 启动独立 app-server。"
        case .helperRelay:
            "Helper Relay：不改桌面 Codex，通过中继连接 Helper app-server。"
        case .desktopRemoteControl:
            "Desktop Remote Control：需要桌面 Codex 开启 remote_control。"
        }
    }
}

struct HistoryStatusCard: View {
    var icon: String
    var title: String
    var detail: String
    var isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(CodexTheme.secondaryText)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(CodexTheme.secondaryText)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(CodexTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(CodexTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }
}

struct LoadMoreHistoryButton: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        Button {
            Task { await store.loadMoreHistory() }
        } label: {
            HStack(spacing: 8) {
                if store.isLoadingMoreHistory {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CodexTheme.secondaryText)
                } else {
                    Image(systemName: "arrow.up.to.line")
                }
                Text(store.isLoadingMoreHistory ? "加载中" : "加载更早内容")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(CodexTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(!store.canLoadMoreHistory)
        .background(CodexTheme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        ZStack {
            CodexTheme.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsHeader
                    ConnectionStatusCard()
                    settingsDetails
                    themePreferences
                    historyPreferences
                    settingsActions
                }
                .padding(20)
            }
        }
    }

    private var settingsHeader: some View {
        HStack {
            Text("设置")
                .font(.title.bold())
                .foregroundStyle(CodexTheme.text)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexTheme.secondaryText)
        }
    }

    private var settingsDetails: some View {
        VStack(spacing: 0) {
            settingsRow(icon: "desktopcomputer", title: "电脑", value: store.pairing?.name ?? "未配对")
            Divider().overlay(CodexTheme.separator)
            settingsRow(icon: "link", title: "连接模式", value: connectionModeValue)
            Divider().overlay(CodexTheme.separator)
            settingsRow(icon: "network", title: "地址", value: pairingAddress)
            Divider().overlay(CodexTheme.separator)
            settingsRow(icon: "folder", title: "工作区", value: store.pairing?.cwd ?? "-")
        }
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }

    private var themePreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外观")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
            Picker(
                "外观",
                selection: Binding(
                    get: { store.themePreference },
                    set: { store.setThemePreference($0) }
                )
            ) {
                ForEach(ThemePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }

    private var historyPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                isOn: Binding(
                    get: { store.shouldLoadHistoryContent },
                    set: { store.setShouldLoadHistoryContent($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("保留历史内容")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CodexTheme.text)
                    Text("关闭后仍显示会话列表，但打开旧会话时不加载旧消息。")
                        .font(.caption)
                        .foregroundStyle(CodexTheme.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .tint(CodexTheme.blue)
        }
        .padding(14)
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }

    private var pairingAddress: String {
        guard let pairing = store.pairing else { return "-" }
        return "\(pairing.host):\(pairing.port)"
    }

    private var connectionModeValue: String {
        guard let pairing = store.pairing else { return "-" }
        return switch pairing.connectionPlan.transport {
        case .helperLAN: "Helper LAN"
        case .helperRelay: "Helper Relay"
        case .desktopRemoteControl: "Remote Control"
        }
    }

    private func settingsRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(CodexTheme.secondaryText)
                .frame(width: 22)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .foregroundStyle(CodexTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var settingsActions: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    Task { await store.reconnect() }
                } label: {
                    Label("重连", systemImage: "arrow.clockwise")
                }
                .buttonStyle(CodexDarkButtonStyle())
                .disabled(!store.canReconnect)

                Button {
                    store.disconnect()
                } label: {
                    Label("断开", systemImage: "power")
                }
                .buttonStyle(CodexDarkButtonStyle())
                .disabled(!store.isConnected)
                Spacer()
            }

            HStack {
                Button(role: .destructive) {
                    store.forgetPairing()
                    dismiss()
                } label: {
                    Label("取消配对", systemImage: "trash")
                }
                .buttonStyle(CodexDarkButtonStyle())
                .disabled(store.pairing == nil)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("完成")
                }
                .buttonStyle(CodexPrimaryButtonStyle())
            }
        }
    }
}

struct ThreadRow: View {
    var thread: CodexThread

    var body: some View {
        SidebarThreadRow(thread: thread, isSelected: false)
    }
}

struct ConversationItemView: View {
    var item: ConversationItem

    var body: some View {
        switch item.kind {
        case .user:
            UserBubble(text: item.body, status: item.status)
        case .fileChange:
            EmptyView()
        default:
            CodexTimelineCard(item: item)
        }
    }
}

struct UserBubble: View {
    var text: String
    var status: String?

    var body: some View {
        HStack {
            Spacer(minLength: 42)
            VStack(alignment: .trailing, spacing: 8) {
                Text(text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(CodexTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(CodexTheme.userBubble, in: RoundedRectangle(cornerRadius: 14))
                if status == "failed" {
                    Label("发送失败，已恢复到输入框", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(CodexTheme.orange)
                }
            }
        }
    }
}

struct CodexTimelineCard: View {
    var item: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(CodexTheme.text)
                Spacer()
                if let status = item.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(CodexTheme.secondaryText)
                }
            }
            if !item.body.isEmpty {
                Text(item.body)
                    .font(item.kind == .command ? .system(.callout, design: .monospaced) : .body)
                    .foregroundStyle(CodexTheme.text)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
    }

    private var icon: String {
        switch item.kind {
        case .assistant: "sparkles"
        case .reasoning: "brain.head.profile"
        case .plan: "list.bullet.rectangle"
        case .command: "terminal"
        case .approval: "checkmark.shield"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .tool: "wrench.and.screwdriver"
        default: "circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .error: .red
        case .warning, .approval: CodexTheme.orange
        case .command: CodexTheme.blue
        case .assistant: .purple
        default: CodexTheme.secondaryText
        }
    }
}

struct ApprovalCard: View {
    @EnvironmentObject private var store: CodexMobileStore
    var approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            approvalTitle
            approvalBody
            approvalActions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private var approvalTitle: some View {
        Label(approval.title, systemImage: "checkmark.shield")
            .font(.headline)
            .foregroundStyle(CodexTheme.orange)
    }

    private var approvalBody: some View {
        Text(approval.body)
            .font(approvalBodyFont)
            .foregroundStyle(CodexTheme.text)
            .textSelection(.enabled)
    }

    private var approvalBodyFont: Font {
        approval.method.contains("command") ? .system(.callout, design: .monospaced) : .callout
    }

    private var approvalActions: some View {
        HStack(spacing: 8) {
            ForEach(approval.decisionOptions) { option in
                approvalButton(option)
            }
        }
    }

    @ViewBuilder
    private func approvalButton(_ option: ApprovalDecisionOption) -> some View {
        let isResponding = store.answeringApprovalID == approval.id
        let isSelected = store.answeringApprovalDecisionID == option.id
        if option.isAffirmative {
            Button {
                Task { await store.answerApproval(option) }
            } label: {
                approvalButtonLabel(option.title, isSelected: isSelected)
            }
            .buttonStyle(CodexPrimaryButtonStyle())
            .disabled(isResponding)
        } else {
            Button {
                Task { await store.answerApproval(option) }
            } label: {
                approvalButtonLabel(option.title, isSelected: isSelected)
            }
            .buttonStyle(CodexDarkButtonStyle())
            .disabled(isResponding)
        }
    }

    private func approvalButtonLabel(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            if isSelected {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(title)
        }
    }
}

struct ComposerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore
    @StateObject private var dictationController = DictationController()
    @State private var dictationBaseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextField("要求后续变更", text: $store.composerText, axis: .vertical)
                    .lineLimit(horizontalSizeClass == .compact ? 1...4 : 2...8)
                    .font(.body)
                    .foregroundStyle(CodexTheme.text)
                    .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 18)
                    .padding(.top, horizontalSizeClass == .compact ? 12 : 16)
                    .padding(.bottom, 8)
                    .background(Color.clear)
                    .textFieldStyle(.plain)
            }
            composerControls
        }
        .onChange(of: dictationController.currentTranscript) { _, transcript in
            applyDictationTranscript(transcript)
        }
        .onChange(of: dictationController.state) { _, state in
            if state != .listening {
                dictationBaseText = store.composerText
            }
        }
        .frame(maxWidth: 900)
        .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 18)
        .padding(.top, horizontalSizeClass == .compact ? 6 : 10)
        .padding(.bottom, horizontalSizeClass == .compact ? 10 : 14)
        .background(CodexTheme.panelRaised, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(CodexTheme.separator, lineWidth: 1)
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 20 : 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, CodexTheme.appBackground.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var composerControls: some View {
        HStack(spacing: horizontalSizeClass == .compact ? 9 : 12) {
            permissionBadge
            modelBadge
            ComposerFeatureControls(
                dictationState: dictationController.state,
                isPlanModeEnabled: Binding(
                    get: { store.isPlanModeEnabled },
                    set: { store.setPlanModeEnabled($0) }
                ),
                isDictationEnabled: !store.conversation.isRunning,
                onDictationTapped: toggleDictation
            )
            .opacity(store.planModeAvailable || !store.isConnected ? 1 : 0.72)
            Spacer(minLength: 6)
            if store.conversation.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(CodexTheme.secondaryText)
            }
            if store.conversation.isRunning {
                Button {
                    Task { await store.interrupt() }
                } label: {
                    ZStack {
                        if store.isInterruptingTurn {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(CodexTheme.orange, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canInterruptTurn)
                .accessibilityLabel(store.isInterruptingTurn ? "正在终止" : "终止当前 turn")
            } else {
                Button {
                    Task { await store.sendComposerText() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(CodexTheme.onSendButton.opacity(store.canSendComposer ? 1 : 0.42))
                        .frame(width: 38, height: 38)
                        .background(sendButtonFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canSendComposer)
            }
        }
        .lineLimit(1)
    }

    private var permissionBadge: some View {
        Menu {
            Section("访问权限") {
                ForEach(CodexPermissionPreset.allCases) { preset in
                    Button {
                        Task { await store.changePermissionPreset(to: preset) }
                    } label: {
                        if store.selectedPermissionPreset == preset {
                            Label(preset.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(preset.displayTitle)
                        }
                    }
                }
            }
        } label: {
            statusChip(
                icon: "exclamationmark.shield",
                title: horizontalSizeClass == .compact ? store.compactPermissionStatusTitle : store.permissionStatusTitle,
                tint: CodexTheme.orange
            )
        }
        .disabled(!store.canChangeSessionSettings)
        .opacity(store.canChangeSessionSettings ? 1 : 0.62)
    }

    private var modelBadge: some View {
        Menu {
            Section("模型") {
                ForEach(store.availableModels) { model in
                    Button {
                        Task { await store.changeModel(to: model) }
                    } label: {
                        if store.selectedModel.model == model.model {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
            Section("推理强度") {
                ForEach(store.availableReasoningEfforts, id: \.self) { effort in
                    Button {
                        Task { await store.changeReasoningEffort(to: effort) }
                    } label: {
                        if store.selectedReasoningEffort == effort {
                            Label(reasoningEffortTitle(effort), systemImage: "checkmark")
                        } else {
                            Text(reasoningEffortTitle(effort))
                        }
                    }
                }
            }
        } label: {
            statusChip(
                icon: "bolt.fill",
                title: horizontalSizeClass == .compact ? store.compactModelStatusTitle : store.modelStatusTitle,
                tint: CodexTheme.secondaryText
            )
        }
        .disabled(!store.canChangeSessionSettings)
        .opacity(store.canChangeSessionSettings ? 1 : 0.62)
    }

    private var sendButtonFill: Color {
        store.canSendComposer ? CodexTheme.sendButtonFill : CodexTheme.tertiaryText.opacity(0.55)
    }

    private func statusChip(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.callout.weight(.bold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CodexTheme.panel, in: Capsule())
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

    private func toggleDictation() {
        switch dictationController.state {
        case .listening:
            dictationController.stop()
            dictationBaseText = store.composerText
        default:
            dictationBaseText = store.composerText
            Task {
                await dictationController.start()
            }
        }
    }

    private func applyDictationTranscript(_ transcript: String) {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let separator = dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        store.composerText = dictationBaseText + separator + transcript
    }
}

struct CodexDarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(CodexTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CodexTheme.panelRaised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CodexPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(CodexTheme.blue.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Codex App Style") {
    CodexMobileRootView()
        .environmentObject(CodexMobileStore.preview())
}

#Preview("Pairing") {
    PairingView()
        .environmentObject(CodexMobileStore())
}

#Preview("Conversation") {
    CodexWorkspaceView()
        .environmentObject(CodexMobileStore.preview())
}
