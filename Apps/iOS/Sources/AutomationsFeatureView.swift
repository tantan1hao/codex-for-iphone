import SwiftUI
import UIKit

struct AutomationsFeatureView: View {
    typealias RefreshAction = @MainActor @Sendable () async -> Void

    enum ContentState: Equatable {
        case unsupported(message: String = "当前 Codex 连接尚未提供自动化接口。")
        case loading
        case error(message: String, lastUpdated: String? = nil)
        case loaded(automations: [Automation], lastUpdated: String? = nil)

        var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }
    }

    struct Automation: Identifiable, Hashable {
        var id: String
        var title: String
        var subtitle: String?
        var status: AutomationStatus
        var scheduleDescription: String?
        var nextRunDescription: String?
        var lastRunDescription: String?
        var detail: Detail

        init(
            id: String,
            title: String,
            subtitle: String? = nil,
            status: AutomationStatus = .unknown("unknown"),
            scheduleDescription: String? = nil,
            nextRunDescription: String? = nil,
            lastRunDescription: String? = nil,
            detail: Detail = Detail()
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.status = status
            self.scheduleDescription = scheduleDescription
            self.nextRunDescription = nextRunDescription
            self.lastRunDescription = lastRunDescription
            self.detail = detail
        }
    }

    struct Detail: Hashable {
        var triggerDescription: String?
        var prompt: String?
        var targetDescription: String?
        var notes: [String]
        var metadata: [MetadataRow]

        init(
            triggerDescription: String? = nil,
            prompt: String? = nil,
            targetDescription: String? = nil,
            notes: [String] = [],
            metadata: [MetadataRow] = []
        ) {
            self.triggerDescription = triggerDescription
            self.prompt = prompt
            self.targetDescription = targetDescription
            self.notes = notes
            self.metadata = metadata
        }
    }

    struct MetadataRow: Identifiable, Hashable {
        var id: String
        var label: String
        var value: String

        init(id: String? = nil, label: String, value: String) {
            self.id = id ?? "\(label)-\(value)"
            self.label = label
            self.value = value
        }
    }

    enum AutomationStatus: Hashable {
        case active
        case paused
        case disabled
        case failed
        case unknown(String)
    }

    private let contentState: ContentState
    private let onRefresh: RefreshAction

    @State private var selectedAutomationID: String?
    @State private var isRefreshing = false

    init(
        state: ContentState = .unsupported(),
        onRefresh: @escaping RefreshAction = {}
    ) {
        self.contentState = state
        self.onRefresh = onRefresh
    }

    var body: some View {
        Group {
            switch contentState {
            case .loaded(let automations, let lastUpdated):
                loadedContent(automations: automations, lastUpdated: lastUpdated)
            case .loading:
                NavigationStack {
                    AutomationsFeatureStatusView(
                        icon: "arrow.triangle.2.circlepath",
                        title: "正在加载自动化",
                        message: "请稍候。",
                        showsProgress: true
                    )
                    .navigationTitle("自动化")
                    .toolbar { refreshToolbarItem }
                }
            case .unsupported(let message):
                NavigationStack {
                    AutomationsFeatureStatusView(
                        icon: "bolt.horizontal.circle",
                        title: "暂不支持",
                        message: message,
                        actionTitle: "刷新",
                        action: startRefresh
                    )
                    .navigationTitle("自动化")
                    .toolbar { refreshToolbarItem }
                }
            case .error(let message, let lastUpdated):
                NavigationStack {
                    AutomationsFeatureStatusView(
                        icon: "exclamationmark.triangle",
                        title: "无法加载自动化",
                        message: message,
                        footnote: lastUpdated.map { "最后更新 \($0)" },
                        actionTitle: "重试",
                        action: startRefresh
                    )
                    .navigationTitle("自动化")
                    .toolbar { refreshToolbarItem }
                }
            }
        }
        .background(AutomationsFeatureTheme.background)
    }

    private func loadedContent(automations: [Automation], lastUpdated: String?) -> some View {
        NavigationSplitView {
            List(selection: $selectedAutomationID) {
                if automations.isEmpty {
                    AutomationsFeatureEmptyRow()
                        .listRowBackground(AutomationsFeatureTheme.panel)
                } else {
                    Section {
                        ForEach(automations) { automation in
                            NavigationLink(value: automation.id) {
                                AutomationRow(automation: automation)
                            }
                            .listRowBackground(AutomationsFeatureTheme.panel)
                        }
                    } footer: {
                        if let lastUpdated {
                            Text("最后更新 \(lastUpdated)")
                                .foregroundStyle(AutomationsFeatureTheme.tertiaryText)
                        }
                    }
                }
            }
            .navigationTitle("自动化")
            .toolbar { refreshToolbarItem }
            .refreshable {
                await performRefresh()
            }
        } detail: {
            if let automation = selectedAutomation(in: automations) {
                AutomationDetailView(automation: automation)
            } else {
                AutomationsFeatureStatusView(
                    icon: "rectangle.stack",
                    title: "没有自动化",
                    message: "连接返回的自动化列表为空。"
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            reconcileSelection(with: automations)
        }
        .onChange(of: automations) { _, newAutomations in
            reconcileSelection(with: newAutomations)
        }
    }

    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: startRefresh) {
                if isRefreshing || contentState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing || contentState.isLoading)
            .accessibilityLabel("刷新自动化")
        }
    }

    private func selectedAutomation(in automations: [Automation]) -> Automation? {
        if let selectedAutomationID,
           let selected = automations.first(where: { $0.id == selectedAutomationID })
        {
            return selected
        }
        return automations.first
    }

    private func reconcileSelection(with automations: [Automation]) {
        guard !automations.isEmpty else {
            selectedAutomationID = nil
            return
        }
        if let selectedAutomationID,
           automations.contains(where: { $0.id == selectedAutomationID })
        {
            return
        }
        selectedAutomationID = automations.first?.id
    }

    private func startRefresh() {
        Task { @MainActor in
            await performRefresh()
        }
    }

    private func performRefresh() async {
        guard !isRefreshing, !contentState.isLoading else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await onRefresh()
    }
}

private struct AutomationRow: View {
    let automation: AutomationsFeatureView.Automation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(automation.title)
                    .font(.headline)
                    .foregroundStyle(AutomationsFeatureTheme.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                AutomationStatusBadge(status: automation.status)
            }

            if let subtitle = automation.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if let scheduleDescription = automation.scheduleDescription {
                    AutomationInlineMetric(icon: "calendar", text: scheduleDescription)
                }
                if let nextRunDescription = automation.nextRunDescription {
                    AutomationInlineMetric(icon: "clock", text: nextRunDescription)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AutomationDetailView: View {
    let automation: AutomationsFeatureView.Automation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryGrid
                if hasDetailRows {
                    detailRows
                }
                if let prompt = automation.detail.prompt, !prompt.isEmpty {
                    promptBlock(prompt)
                }
                if !automation.detail.notes.isEmpty {
                    notesBlock
                }
                if !automation.detail.metadata.isEmpty {
                    metadataRows
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(AutomationsFeatureTheme.background)
        .navigationTitle(automation.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: automation.status.iconName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(automation.status.tint)
                    .frame(width: 42, height: 42)
                    .background(automation.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(automation.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AutomationsFeatureTheme.text)
                            .lineLimit(3)
                        AutomationStatusBadge(status: automation.status)
                    }

                    if let subtitle = automation.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)], spacing: 12) {
            AutomationSummaryTile(
                icon: "calendar",
                title: "计划",
                value: automation.scheduleDescription ?? "-"
            )
            AutomationSummaryTile(
                icon: "clock",
                title: "下次运行",
                value: automation.nextRunDescription ?? "-"
            )
            AutomationSummaryTile(
                icon: "checkmark.circle",
                title: "上次运行",
                value: automation.lastRunDescription ?? "-"
            )
        }
    }

    private var hasDetailRows: Bool {
        automation.detail.triggerDescription != nil || automation.detail.targetDescription != nil
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            if let triggerDescription = automation.detail.triggerDescription {
                AutomationDetailRow(icon: "bolt", title: "触发器", value: triggerDescription)
            }
            if automation.detail.triggerDescription != nil,
               automation.detail.targetDescription != nil
            {
                Divider().overlay(AutomationsFeatureTheme.separator)
            }
            if let targetDescription = automation.detail.targetDescription {
                AutomationDetailRow(icon: "scope", title: "目标", value: targetDescription)
            }
        }
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }

    private func promptBlock(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt")
                .font(.headline)
                .foregroundStyle(AutomationsFeatureTheme.text)
            Text(prompt)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(AutomationsFeatureTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("备注")
                .font(.headline)
                .foregroundStyle(AutomationsFeatureTheme.text)
            ForEach(automation.detail.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(AutomationsFeatureTheme.tertiaryText)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }

    private var metadataRows: some View {
        VStack(spacing: 0) {
            ForEach(automation.detail.metadata) { row in
                AutomationDetailRow(icon: "info.circle", title: row.label, value: row.value)
                if row.id != automation.detail.metadata.last?.id {
                    Divider().overlay(AutomationsFeatureTheme.separator)
                }
            }
        }
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }
}

private struct AutomationStatusBadge: View {
    let status: AutomationsFeatureView.AutomationStatus

    var body: some View {
        Label(status.displayTitle, systemImage: status.iconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.12), in: Capsule())
    }
}

private struct AutomationInlineMetric: View {
    var icon: String
    var text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(AutomationsFeatureTheme.secondaryText)
            .lineLimit(1)
    }
}

private struct AutomationSummaryTile: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AutomationsFeatureTheme.secondaryText)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(AutomationsFeatureTheme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(12)
        .background(AutomationsFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AutomationsFeatureTheme.separator, lineWidth: 1)
        }
    }
}

private struct AutomationDetailRow: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(AutomationsFeatureTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct AutomationsFeatureEmptyRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("没有自动化", systemImage: "rectangle.stack.badge.minus")
                .font(.headline)
                .foregroundStyle(AutomationsFeatureTheme.text)
            Text("当前连接返回空列表。")
                .font(.subheadline)
                .foregroundStyle(AutomationsFeatureTheme.secondaryText)
        }
        .padding(.vertical, 12)
    }
}

private struct AutomationsFeatureStatusView: View {
    var icon: String
    var title: String
    var message: String
    var footnote: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var showsProgress = false

    var body: some View {
        VStack(spacing: 16) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(AutomationsFeatureTheme.secondaryText)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AutomationsFeatureTheme.text)
                Text(message)
                    .font(.body)
                    .foregroundStyle(AutomationsFeatureTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(AutomationsFeatureTheme.tertiaryText)
                }
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AutomationsFeatureTheme.background)
    }
}

private enum AutomationsFeatureTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    static let text = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let green = Color(uiColor: .systemGreen)
    static let orange = Color(uiColor: .systemOrange)
    static let blue = Color(uiColor: .systemBlue)
    static let red = Color(uiColor: .systemRed)
}

private extension AutomationsFeatureView.AutomationStatus {
    var displayTitle: String {
        switch self {
        case .active: "运行中"
        case .paused: "已暂停"
        case .disabled: "已停用"
        case .failed: "失败"
        case let .unknown(value): value.isEmpty ? "未知" : value
        }
    }

    var iconName: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .disabled: "slash.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: AutomationsFeatureTheme.green
        case .paused: AutomationsFeatureTheme.orange
        case .disabled, .unknown: AutomationsFeatureTheme.secondaryText
        case .failed: AutomationsFeatureTheme.red
        }
    }
}

#Preview("Automations") {
    AutomationsFeatureView(
        state: .loaded(
            automations: [
                .init(
                    id: "daily-summary",
                    title: "Daily repo summary",
                    subtitle: "Summarizes overnight changes for the active workspace.",
                    status: .active,
                    scheduleDescription: "Every weekday 09:00",
                    nextRunDescription: "Today 09:00",
                    lastRunDescription: "Yesterday 09:01",
                    detail: .init(
                        triggerDescription: "Weekday schedule",
                        prompt: "Review open PRs and produce a short summary.",
                        targetDescription: "/Users/mac/CodexMobile",
                        notes: ["Read-only preview data.", "Editing controls intentionally omitted."],
                        metadata: [
                            .init(label: "Created by", value: "Codex"),
                            .init(label: "Timezone", value: "Asia/Shanghai"),
                        ]
                    )
                ),
                .init(
                    id: "release-check",
                    title: "Release checklist",
                    status: .paused,
                    scheduleDescription: "Manual",
                    lastRunDescription: "Apr 29"
                ),
            ],
            lastUpdated: "刚刚"
        )
    )
}
