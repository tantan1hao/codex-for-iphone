import SwiftUI
import UIKit

struct TerminalFeatureView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: CodexMobileStore
    @StateObject private var state: TerminalFeatureState

    private let injectedActions: TerminalFeatureActions?

    init(
        state: @autoclosure @escaping () -> TerminalFeatureState = TerminalFeatureState(),
        actions: TerminalFeatureActions? = nil
    ) {
        _state = StateObject(wrappedValue: state())
        self.injectedActions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outputPane
            Divider()
            commandBar
        }
        .background(TerminalColors.background)
        .onAppear {
            state.updateWorkingDirectory(resolvedWorkingDirectory)
        }
        .onChange(of: resolvedWorkingDirectory) { _, newValue in
            state.updateWorkingDirectory(newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Terminal", systemImage: "terminal")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(CodexTheme.text)
                Spacer(minLength: 8)
                TerminalStatusBadge(status: state.status)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(CodexTheme.secondaryText)
                    .frame(width: 18)
                Text(state.displayWorkingDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(CodexTheme.secondaryText)
                    .lineLimit(horizontalSizeClass == .compact ? 2 : 1)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 22)
        .padding(.vertical, 14)
        .background(TerminalColors.panel)
    }

    private var outputPane: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.lines.isEmpty {
                        TerminalPlaceholderView()
                    } else {
                        ForEach(state.lines) { line in
                            TerminalOutputLineView(line: line)
                                .id(line.id)
                        }
                    }
                }
                .padding(horizontalSizeClass == .compact ? 14 : 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .scrollDismissesKeyboard(.interactively)
            .background(TerminalColors.outputBackground)
            .onChange(of: state.scrollAnchorID) { _, anchorID in
                guard let anchorID else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    scrollProxy.scrollTo(anchorID, anchor: .bottom)
                }
            }
        }
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.statusMessage {
                TerminalMessageView(message: message, isError: state.status.isError)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Command", text: $state.commandText, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(TerminalColors.field, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(TerminalColors.separator, lineWidth: 1)
                    }
                    .onSubmit {
                        runCommand()
                    }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        runButton
                        stopButton
                        clearButton
                    }
                    HStack(spacing: 6) {
                        runIconButton
                        stopIconButton
                        clearIconButton
                    }
                }
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 18)
        .padding(.vertical, 12)
        .background(TerminalColors.panel)
    }

    private var runButton: some View {
        Button {
            runCommand()
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .buttonStyle(TerminalButtonStyle(kind: .primary))
        .disabled(!state.canRun)
    }

    private var stopButton: some View {
        Button {
            stopCommand()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(TerminalButtonStyle(kind: .destructive))
        .disabled(!state.canStop)
    }

    private var clearButton: some View {
        Button {
            state.clear()
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .buttonStyle(TerminalButtonStyle(kind: .secondary))
        .disabled(state.lines.isEmpty)
    }

    private var runIconButton: some View {
        Button {
            runCommand()
        } label: {
            Image(systemName: "play.fill")
                .frame(width: 38, height: 38)
        }
        .buttonStyle(TerminalButtonStyle(kind: .primary))
        .disabled(!state.canRun)
        .accessibilityLabel("Run")
    }

    private var stopIconButton: some View {
        Button {
            stopCommand()
        } label: {
            Image(systemName: "stop.fill")
                .frame(width: 38, height: 38)
        }
        .buttonStyle(TerminalButtonStyle(kind: .destructive))
        .disabled(!state.canStop)
        .accessibilityLabel("Stop")
    }

    private var clearIconButton: some View {
        Button {
            state.clear()
        } label: {
            Image(systemName: "trash")
                .frame(width: 38, height: 38)
        }
        .buttonStyle(TerminalButtonStyle(kind: .secondary))
        .disabled(state.lines.isEmpty)
        .accessibilityLabel("Clear")
    }

    private var actions: TerminalFeatureActions {
        if let injectedActions {
            return injectedActions
        }
        if let provider = store as? TerminalFeatureActionProviding {
            return provider.terminalFeatureActions
        }
        return .unsupported
    }

    private var resolvedWorkingDirectory: String {
        let selectedThreadCWD = store.selectedThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedThreadCWD, !selectedThreadCWD.isEmpty {
            return selectedThreadCWD
        }
        let pairingCWD = store.pairing?.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pairingCWD, !pairingCWD.isEmpty {
            return pairingCWD
        }
        return ""
    }

    private func runCommand() {
        Task {
            await state.run(actions: actions)
        }
    }

    private func stopCommand() {
        Task {
            await state.stop(actions: actions)
        }
    }
}

@MainActor
protocol TerminalFeatureActionProviding: AnyObject {
    var terminalFeatureActions: TerminalFeatureActions { get }
}

struct TerminalFeatureActions {
    var run: @Sendable @MainActor (TerminalCommandRequest) async throws -> AsyncThrowingStream<TerminalCommandEvent, Error>
    var stop: @Sendable @MainActor () async -> Void

    init(
        run: @escaping @Sendable @MainActor (TerminalCommandRequest) async throws -> AsyncThrowingStream<TerminalCommandEvent, Error>,
        stop: @escaping @Sendable @MainActor () async -> Void = {}
    ) {
        self.run = run
        self.stop = stop
    }

    static let unsupported = TerminalFeatureActions(
        run: { _ in
            throw TerminalFeatureError.unsupported
        }
    )
}

struct TerminalCommandRequest: Equatable, Sendable {
    var command: String
    var cwd: String
}

enum TerminalCommandEvent: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
    case interaction(String)
    case completed(exitCode: Int?)
}

enum TerminalFeatureError: LocalizedError, Sendable {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "Terminal command execution is not wired to app-server command/exec in this build."
        }
    }
}

@MainActor
final class TerminalFeatureState: ObservableObject {
    @Published var commandText = ""
    @Published private(set) var workingDirectory = ""
    @Published private(set) var lines: [TerminalOutputLine] = []
    @Published private(set) var status: TerminalRunStatus = .idle

    private var runTask: Task<Void, Never>?

    var canRun: Bool {
        !trimmedCommand.isEmpty && !status.isBusy
    }

    var canStop: Bool {
        status.isBusy
    }

    var displayWorkingDirectory: String {
        workingDirectory.isEmpty ? "No workspace selected" : workingDirectory
    }

    var scrollAnchorID: TerminalOutputLine.ID? {
        lines.last?.id
    }

    var statusMessage: String? {
        switch status {
        case .idle, .running, .stopping:
            nil
        case let .failed(message), let .unsupported(message):
            message
        }
    }

    func updateWorkingDirectory(_ value: String) {
        workingDirectory = value
    }

    func run(actions: TerminalFeatureActions) async {
        let command = trimmedCommand
        guard !command.isEmpty, !status.isBusy else { return }

        status = .running
        append(command, stream: .interaction, prefix: "$")
        commandText = ""

        let request = TerminalCommandRequest(command: command, cwd: workingDirectory)
        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consumeRunStream(request: request, actions: actions)
        }
    }

    func stop(actions: TerminalFeatureActions) async {
        guard status.isBusy else { return }
        status = .stopping
        append("stop requested", stream: .interaction, prefix: nil)
        runTask?.cancel()
        await actions.stop()
        status = .idle
    }

    func clear() {
        lines.removeAll()
        if !status.isBusy {
            status = .idle
        }
    }

    func appendOutput(_ text: String, stream: TerminalOutputStream) {
        append(text, stream: stream, prefix: nil)
    }

    func appendInteraction(_ text: String) {
        append(text, stream: .interaction, prefix: nil)
    }

    private func consumeRunStream(request: TerminalCommandRequest, actions: TerminalFeatureActions) async {
        do {
            let stream = try await actions.run(request)
            var didReceiveCompletion = false
            for try await event in stream {
                guard !Task.isCancelled else { return }
                if apply(event) {
                    didReceiveCompletion = true
                }
            }
            guard !Task.isCancelled else { return }
            if !didReceiveCompletion {
                status = .idle
            }
        } catch is CancellationError {
        } catch TerminalFeatureError.unsupported {
            let message = TerminalFeatureError.unsupported.localizedDescription
            append(message, stream: .stderr, prefix: nil)
            status = .unsupported(message)
        } catch {
            let message = error.localizedDescription
            append(message, stream: .stderr, prefix: nil)
            status = .failed(message)
        }
    }

    @discardableResult
    private func apply(_ event: TerminalCommandEvent) -> Bool {
        switch event {
        case let .stdout(text):
            append(text, stream: .stdout, prefix: nil)
            return false
        case let .stderr(text):
            append(text, stream: .stderr, prefix: nil)
            return false
        case let .interaction(text):
            append(text, stream: .interaction, prefix: nil)
            return false
        case let .completed(exitCode):
            if let exitCode, exitCode != 0 {
                let message = "Process exited with code \(exitCode)."
                append(message, stream: .stderr, prefix: nil)
                status = .failed(message)
            } else if let exitCode {
                append("Process exited with code \(exitCode).", stream: .interaction, prefix: nil)
                status = .idle
            } else {
                status = .idle
            }
            return true
        }
    }

    private func append(_ text: String, stream: TerminalOutputStream, prefix: String?) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visibleParts = normalized.hasSuffix("\n") ? parts.dropLast() : parts[...]

        for part in visibleParts {
            lines.append(
                TerminalOutputLine(
                    stream: stream,
                    text: part,
                    prefix: prefix,
                    timestamp: .now
                )
            )
        }
    }

    private var trimmedCommand: String {
        commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TerminalRunStatus: Equatable {
    case idle
    case running
    case stopping
    case failed(String)
    case unsupported(String)

    var isBusy: Bool {
        switch self {
        case .running, .stopping:
            true
        case .idle, .failed, .unsupported:
            false
        }
    }

    var isError: Bool {
        switch self {
        case .failed, .unsupported:
            true
        case .idle, .running, .stopping:
            false
        }
    }
}

struct TerminalOutputLine: Identifiable, Equatable {
    let id = UUID()
    var stream: TerminalOutputStream
    var text: String
    var prefix: String?
    var timestamp: Date
}

enum TerminalOutputStream: String, Equatable, Sendable {
    case stdout
    case stderr
    case interaction

    var title: String {
        switch self {
        case .stdout:
            "out"
        case .stderr:
            "err"
        case .interaction:
            "term"
        }
    }

    var tint: Color {
        switch self {
        case .stdout:
            CodexTheme.text
        case .stderr:
            Color(uiColor: .systemRed)
        case .interaction:
            CodexTheme.blue
        }
    }
}

private struct TerminalStatusBadge: View {
    var status: TerminalRunStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch status {
        case .idle:
            "Idle"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .failed:
            "Error"
        case .unsupported:
            "Unsupported"
        }
    }

    private var tint: Color {
        switch status {
        case .idle:
            CodexTheme.secondaryText
        case .running:
            CodexTheme.green
        case .stopping:
            CodexTheme.orange
        case .failed, .unsupported:
            Color(uiColor: .systemRed)
        }
    }
}

private struct TerminalOutputLineView: View {
    var line: TerminalOutputLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.stream.title)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(line.stream.tint)
                .frame(width: 34, alignment: .trailing)
            Text(lineText)
                .foregroundStyle(line.stream.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lineText: String {
        if let prefix = line.prefix {
            "\(prefix) \(line.text)"
        } else {
            line.text
        }
    }
}

private struct TerminalPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(CodexTheme.secondaryText)
            Text("No terminal output yet.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CodexTheme.text)
            Text("Run a command after the app-server command/exec hook is wired.")
                .font(.caption)
                .foregroundStyle(CodexTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
    }
}

private struct TerminalMessageView: View {
    var message: String
    var isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(isError ? Color(uiColor: .systemRed) : CodexTheme.secondaryText)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var background: Color {
        isError ? Color(uiColor: .systemRed).opacity(0.10) : TerminalColors.field
    }
}

private struct TerminalButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.88 : 1)
    }

    private var background: Color {
        switch kind {
        case .primary:
            CodexTheme.blue
        case .secondary:
            TerminalColors.field
        case .destructive:
            CodexTheme.orange
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive:
            .white
        case .secondary:
            CodexTheme.text
        }
    }
}

private enum TerminalColors {
    static let background = CodexTheme.appBackground
    static let panel = CodexTheme.panelRaised
    static let field = CodexTheme.panel
    static let outputBackground = CodexTheme.appBackground
    static let separator = CodexTheme.separator
}

#Preview("Terminal") {
    TerminalFeatureView()
        .environmentObject(CodexMobileStore.preview())
}
