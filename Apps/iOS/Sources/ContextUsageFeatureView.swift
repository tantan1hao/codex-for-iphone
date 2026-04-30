import SwiftUI
import UIKit

struct ContextUsageFeatureView: View {
    typealias RefreshAction = @MainActor @Sendable () async -> Void
    typealias CompactAction = @MainActor @Sendable () async -> Void

    enum ContentState: Equatable {
        case unsupported(message: String = "当前 Codex 连接尚未提供上下文用量接口。")
        case loading
        case error(message: String, lastUpdated: String? = nil)
        case loaded(Snapshot)

        var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }
    }

    struct Snapshot: Equatable {
        var remainingFraction: Double?
        var tokensInContext: Int?
        var contextWindow: Int?
        var compactStatus: CompactStatus
        var lastUpdated: String?

        init(
            remainingFraction: Double? = nil,
            tokensInContext: Int? = nil,
            contextWindow: Int? = nil,
            compactStatus: CompactStatus = .unavailable("Compact 状态不可用"),
            lastUpdated: String? = nil
        ) {
            self.remainingFraction = remainingFraction
            self.tokensInContext = tokensInContext
            self.contextWindow = contextWindow
            self.compactStatus = compactStatus
            self.lastUpdated = lastUpdated
        }

        var resolvedRemainingFraction: Double? {
            if let remainingFraction {
                return remainingFraction.clamped(to: 0...1)
            }
            guard let tokensInContext,
                  let contextWindow,
                  contextWindow > 0
            else { return nil }
            return (1 - Double(tokensInContext) / Double(contextWindow)).clamped(to: 0...1)
        }

        var usedFraction: Double? {
            resolvedRemainingFraction.map { 1 - $0 }
        }

        var remainingTokens: Int? {
            guard let tokensInContext,
                  let contextWindow
            else { return nil }
            return max(contextWindow - tokensInContext, 0)
        }
    }

    enum CompactStatus: Equatable {
        case unavailable(String)
        case notNeeded
        case available
        case compacting
        case compacted(message: String? = nil)
        case failed(String)

        var allowsManualCompact: Bool {
            switch self {
            case .available, .failed:
                true
            case .unavailable, .notNeeded, .compacting, .compacted:
                false
            }
        }
    }

    private let contentState: ContentState
    private let onRefresh: RefreshAction
    private let onRequestCompact: CompactAction

    @State private var isRefreshing = false
    @State private var isRequestingCompact = false

    init(
        state: ContentState = .unsupported(),
        onRefresh: @escaping RefreshAction = {},
        onRequestCompact: @escaping CompactAction = {}
    ) {
        self.contentState = state
        self.onRefresh = onRefresh
        self.onRequestCompact = onRequestCompact
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("上下文")
                .toolbar { refreshToolbarItem }
        }
        .background(ContextUsageFeatureTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch contentState {
        case .loaded(let snapshot):
            loadedContent(snapshot)
        case .loading:
            ContextUsageStatusView(
                icon: "arrow.triangle.2.circlepath",
                title: "正在加载上下文用量",
                message: "请稍候。",
                showsProgress: true
            )
        case .unsupported(let message):
            ContextUsageStatusView(
                icon: "chart.pie",
                title: "暂不支持",
                message: message,
                actionTitle: "刷新",
                action: startRefresh
            )
        case .error(let message, let lastUpdated):
            ContextUsageStatusView(
                icon: "exclamationmark.triangle",
                title: "无法加载上下文用量",
                message: message,
                footnote: lastUpdated.map { "最后更新 \($0)" },
                actionTitle: "重试",
                action: startRefresh
            )
        }
    }

    private func loadedContent(_ snapshot: Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ContextOverviewCard(snapshot: snapshot)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
                    ContextMetricTile(
                        icon: "text.append",
                        title: "Tokens in context",
                        value: formattedTokens(snapshot.tokensInContext)
                    )
                    ContextMetricTile(
                        icon: "rectangle.expand.vertical",
                        title: "Context window",
                        value: formattedTokens(snapshot.contextWindow)
                    )
                    ContextMetricTile(
                        icon: "minus.forwardslash.plus",
                        title: "剩余 tokens",
                        value: formattedTokens(snapshot.remainingTokens)
                    )
                }

                CompactStatusCard(
                    status: snapshot.compactStatus,
                    isRequestingCompact: isRequestingCompact,
                    action: startCompactRequest
                )

                if let lastUpdated = snapshot.lastUpdated {
                    Text("最后更新 \(lastUpdated)")
                        .font(.caption)
                        .foregroundStyle(ContextUsageFeatureTheme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .refreshable {
            await performRefresh()
        }
        .background(ContextUsageFeatureTheme.background)
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
            .accessibilityLabel("刷新上下文用量")
        }
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

    private func startCompactRequest() {
        Task { @MainActor in
            await performCompactRequest()
        }
    }

    private func performCompactRequest() async {
        guard !isRequestingCompact,
              case let .loaded(snapshot) = contentState,
              snapshot.compactStatus.allowsManualCompact
        else { return }
        isRequestingCompact = true
        defer { isRequestingCompact = false }
        await onRequestCompact()
    }

    private func formattedTokens(_ value: Int?) -> String {
        guard let value else { return "-" }
        return value.formatted(.number)
    }
}

private struct ContextOverviewCard: View {
    let snapshot: ContextUsageFeatureView.Snapshot

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ContextUsageRing(fractionRemaining: snapshot.resolvedRemainingFraction)
                .frame(width: 126, height: 126)

            VStack(alignment: .leading, spacing: 10) {
                Label("上下文剩余", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                    .foregroundStyle(ContextUsageFeatureTheme.text)

                Text(percentText(snapshot.resolvedRemainingFraction))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(snapshot.remainingTint)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)

                Text(usageSentence)
                    .font(.callout)
                    .foregroundStyle(ContextUsageFeatureTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ContextUsageFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(ContextUsageFeatureTheme.separator, lineWidth: 1)
        }
    }

    private var usageSentence: String {
        guard let tokensInContext = snapshot.tokensInContext,
              let contextWindow = snapshot.contextWindow
        else { return "等待 Codex 返回 token 统计。" }
        return "\(tokensInContext.formatted(.number)) / \(contextWindow.formatted(.number)) tokens"
    }

    private func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "-" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct ContextUsageRing: View {
    var fractionRemaining: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(ContextUsageFeatureTheme.separator, lineWidth: 14)

            Circle()
                .trim(from: 0, to: fractionRemaining ?? 0)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: iconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        guard let fractionRemaining else {
            return ContextUsageFeatureTheme.secondaryText
        }
        if fractionRemaining <= 0.12 {
            return ContextUsageFeatureTheme.red
        }
        if fractionRemaining <= 0.25 {
            return ContextUsageFeatureTheme.orange
        }
        return ContextUsageFeatureTheme.green
    }

    private var iconName: String {
        guard fractionRemaining != nil else { return "questionmark" }
        return "text.magnifyingglass"
    }
}

private struct ContextMetricTile: View {
    var icon: String
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ContextUsageFeatureTheme.secondaryText)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ContextUsageFeatureTheme.text)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(12)
        .background(ContextUsageFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(ContextUsageFeatureTheme.separator, lineWidth: 1)
        }
    }
}

private struct CompactStatusCard: View {
    var status: ContextUsageFeatureView.CompactStatus
    var isRequestingCompact: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(status.tint)
                    .frame(width: 36, height: 36)
                    .background(status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(ContextUsageFeatureTheme.text)
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(ContextUsageFeatureTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button(action: action) {
                if isRequestingCompact || status == .compacting {
                    Label("Compacting", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("手动 compact", systemImage: "rectangle.compress.vertical")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingCompact || !status.allowsManualCompact)
        }
        .padding(16)
        .background(ContextUsageFeatureTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(ContextUsageFeatureTheme.separator, lineWidth: 1)
        }
    }
}

private struct ContextUsageStatusView: View {
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
                    .foregroundStyle(ContextUsageFeatureTheme.secondaryText)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ContextUsageFeatureTheme.text)
                Text(message)
                    .font(.body)
                    .foregroundStyle(ContextUsageFeatureTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(ContextUsageFeatureTheme.tertiaryText)
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
        .background(ContextUsageFeatureTheme.background)
    }
}

private enum ContextUsageFeatureTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    static let text = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let green = Color(uiColor: .systemGreen)
    static let orange = Color(uiColor: .systemOrange)
    static let red = Color(uiColor: .systemRed)
    static let blue = Color(uiColor: .systemBlue)
}

private extension ContextUsageFeatureView.Snapshot {
    var remainingTint: Color {
        guard let resolvedRemainingFraction else {
            return ContextUsageFeatureTheme.secondaryText
        }
        if resolvedRemainingFraction <= 0.12 {
            return ContextUsageFeatureTheme.red
        }
        if resolvedRemainingFraction <= 0.25 {
            return ContextUsageFeatureTheme.orange
        }
        return ContextUsageFeatureTheme.green
    }
}

private extension ContextUsageFeatureView.CompactStatus {
    var title: String {
        switch self {
        case .unavailable: "Compact 状态不可用"
        case .notNeeded: "无需 compact"
        case .available: "可以 compact"
        case .compacting: "Compact 进行中"
        case .compacted: "已 compact"
        case .failed: "Compact 失败"
        }
    }

    var detail: String {
        switch self {
        case let .unavailable(message):
            message
        case .notNeeded:
            "当前上下文仍有足够空间。"
        case .available:
            "可以请求 Codex 压缩当前上下文。"
        case .compacting:
            "Codex 正在压缩上下文。"
        case let .compacted(message):
            message ?? "当前上下文已经完成压缩。"
        case let .failed(message):
            message
        }
    }

    var iconName: String {
        switch self {
        case .unavailable: "questionmark.circle"
        case .notNeeded: "checkmark.circle"
        case .available: "rectangle.compress.vertical"
        case .compacting: "arrow.triangle.2.circlepath"
        case .compacted: "checkmark.seal"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .unavailable: ContextUsageFeatureTheme.secondaryText
        case .notNeeded, .compacted: ContextUsageFeatureTheme.green
        case .available, .compacting: ContextUsageFeatureTheme.blue
        case .failed: ContextUsageFeatureTheme.red
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

#Preview("Context usage") {
    ContextUsageFeatureView(
        state: .loaded(
            .init(
                remainingFraction: 0.37,
                tokensInContext: 128_240,
                contextWindow: 200_000,
                compactStatus: .available,
                lastUpdated: "刚刚"
            )
        )
    )
}
