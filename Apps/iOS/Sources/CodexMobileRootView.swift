import CodexMobileKit
import SwiftUI

private enum CodexTheme {
    static let appBackground = Color(red: 0.055, green: 0.055, blue: 0.055)
    static let sidebarTop = Color(red: 0.16, green: 0.14, blue: 0.24)
    static let sidebarBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.105)
    static let panelRaised = Color(red: 0.135, green: 0.135, blue: 0.135)
    static let selected = Color.white.opacity(0.12)
    static let separator = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.34)
    static let green = Color(red: 0.18, green: 0.76, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.45, blue: 0.18)
    static let blue = Color(red: 0.36, green: 0.63, blue: 1.0)
}

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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.isScannerPresented) {
            QRScannerSheet { value in
                store.pairingText = value
                store.isScannerPresented = false
                Task { await store.connectFromText() }
            }
        }
        .sheet(isPresented: $store.isSettingsPresented) {
            SettingsView()
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
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
            if store.pairing == nil {
                PairingView()
            } else {
                CodexWorkspaceView()
            }
        }
        .background(CodexTheme.appBackground)
    }
}

struct CompactCodexRoot: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                if store.pairing == nil {
                    PairingView()
                } else {
                    CodexWorkspaceView()
                }
            }
            .background(CodexTheme.appBackground)

            if store.isSidebarPresented {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        store.isSidebarPresented = false
                    }

                CompactSidebarDrawer()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.24), value: store.isSidebarPresented)
    }
}

struct CodexSidebar: View {
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarTopChrome
            sidebarActions
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
        VStack(alignment: .leading, spacing: 18) {
            SidebarAction(icon: "square.and.pencil", title: "新对话") {
                Task { await store.startNewThread() }
            }
            SidebarAction(icon: "magnifyingglass", title: "搜索") {}
            SidebarAction(icon: "circle.grid.2x2", title: "插件") {}
            SidebarAction(icon: "clock.arrow.circlepath", title: "自动化") {}
        }
        .padding(.bottom, 34)
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("项目")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CodexTheme.tertiaryText)
                Spacer()
                Image(systemName: "line.3.horizontal.decrease")
                Image(systemName: "folder.badge.plus")
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
                    SidebarThreadRow(
                        thread: thread,
                        isSelected: store.selectedThread?.id == thread.id
                    )
                    .onTapGesture {
                        Task { await store.select(thread) }
                    }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("项目")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CodexTheme.tertiaryText)
                        ForEach(store.threads) { thread in
                            SidebarThreadRow(
                                thread: thread,
                                isSelected: store.selectedThread?.id == thread.id
                            )
                            .onTapGesture {
                                Task {
                                    await store.select(thread)
                                    await MainActor.run {
                                        store.isSidebarPresented = false
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
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
    var body: some View {
        GeometryReader { proxy in
            let drawerHeight = max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom - 20)
            CompactThreadListView()
                .frame(width: min(proxy.size.width * 0.86, 336), height: drawerHeight)
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
        .toolbarColorScheme(.dark, for: .navigationBar)
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
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            ScrollView {
                VStack(spacing: 22) {
                    if store.selectedThread == nil {
                        EmptyDarkWorkspace()
                    } else {
                        changeSummaryIfNeeded
                        ForEach(store.conversation.items) { item in
                            ConversationItemView(item: item)
                        }
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 170)
                .frame(maxWidth: .infinity)
            }
            .background(CodexTheme.appBackground)
            ComposerView()
        }
        .background(CodexTheme.appBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private var changeSummaryIfNeeded: some View {
        if store.conversation.items.contains(where: { $0.kind == .fileChange }) {
            CodexChangeSummaryView()
        }
        if let approval = store.conversation.activeApproval {
            ApprovalCard(approval: approval)
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
            }
            Button {} label: {
                Image(systemName: "chevron.right")
            }
            Text(store.selectedThread?.displayTitle ?? "查看 Codex 项目")
                .font(.headline.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {} label: {
                Image(systemName: "terminal")
            }
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private var regularHeader: some View {
        Group {
            Button {} label: {
                Image(systemName: "chevron.left")
            }
            Button {} label: {
                Image(systemName: "chevron.right")
            }
            Text(store.selectedThread?.displayTitle ?? "查看 Codex 项目")
                .font(.headline.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
                .lineLimit(1)
            Text(store.pairing?.name ?? "mac")
                .font(.headline)
                .foregroundStyle(CodexTheme.tertiaryText)
            Button {
                store.isSettingsPresented = true
            } label: {
                Image(systemName: "ellipsis")
            }
            Spacer()
            Button {} label: {
                Image(systemName: "terminal")
            }
            Button {} label: {
                Image(systemName: "folder")
            }
            Button {} label: {
                Image(systemName: "sidebar.right")
            }
        }
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
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CodexTheme.secondaryText)
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
                Text("\(pairing.name)  \(pairing.host):\(pairing.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(CodexTheme.tertiaryText)
                    .lineLimit(2)
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
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CodexMobileStore

    var body: some View {
        ZStack {
            CodexTheme.appBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader
                ConnectionStatusCard()
                settingsDetails
                Spacer(minLength: 8)
                settingsActions
            }
            .padding(20)
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

    private var pairingAddress: String {
        guard let pairing = store.pairing else { return "-" }
        return "\(pairing.host):\(pairing.port)"
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
        HStack {
            Button {
                store.disconnect()
                dismiss()
            } label: {
                Label("断开连接", systemImage: "power")
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
            UserBubble(text: item.body)
        case .fileChange:
            EmptyView()
        default:
            CodexTimelineCard(item: item)
        }
    }
}

struct UserBubble: View {
    var text: String

    var body: some View {
        HStack {
            Spacer(minLength: 42)
            VStack(alignment: .trailing, spacing: 8) {
                Text(text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(CodexTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 12) {
                    Text("19:31")
                    Image(systemName: "doc.on.doc")
                    Image(systemName: "pencil")
                }
                .font(.caption)
                .foregroundStyle(CodexTheme.tertiaryText)
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
        HStack {
            ForEach(approval.availableDecisions, id: \.self) { decision in
                approvalButton(decision)
            }
        }
    }

    @ViewBuilder
    private func approvalButton(_ decision: String) -> some View {
        if decision == "accept" {
            Button(decisionTitle(decision)) {
                Task { await store.answerApproval(decision) }
            }
            .buttonStyle(CodexPrimaryButtonStyle())
        } else {
            Button(decisionTitle(decision)) {
                Task { await store.answerApproval(decision) }
            }
            .buttonStyle(CodexDarkButtonStyle())
        }
    }

    private func decisionTitle(_ decision: String) -> String {
        switch decision {
        case "accept": "批准"
        case "acceptForSession": "本会话批准"
        case "decline": "拒绝"
        case "cancel": "取消"
        default: decision
        }
    }
}

struct ComposerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore

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
            Button {} label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            permissionBadge
            Spacer(minLength: 6)
            if store.conversation.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(CodexTheme.secondaryText)
            }
            Image(systemName: "bolt.fill")
                .foregroundStyle(CodexTheme.secondaryText)
            Text(horizontalSizeClass == .compact ? "5.5" : "5.5 超高")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(CodexTheme.secondaryText)
            if horizontalSizeClass != .compact {
                Image(systemName: "mic")
                    .foregroundStyle(CodexTheme.secondaryText)
            }
            Button {
                Task { await store.sendComposerText() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(CodexTheme.text, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .lineLimit(1)
    }

    private var permissionBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield")
            Text(horizontalSizeClass == .compact ? "权限" : "完全访问权限")
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .font(.callout.weight(.bold))
        .foregroundStyle(CodexTheme.orange)
        .lineLimit(1)
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
