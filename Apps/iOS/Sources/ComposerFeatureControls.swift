import SwiftUI

struct ComposerFeatureControls: View {
    @Binding private var isPlanModeEnabled: Bool
    private var dictationState: DictationState
    private var isDictationEnabled: Bool
    private var onDictationTapped: () -> Void

    init(
        dictationState: DictationState,
        isPlanModeEnabled: Binding<Bool>,
        isDictationEnabled: Bool = true,
        onDictationTapped: @escaping () -> Void
    ) {
        self.dictationState = dictationState
        self._isPlanModeEnabled = isPlanModeEnabled
        self.isDictationEnabled = isDictationEnabled
        self.onDictationTapped = onDictationTapped
    }

    var body: some View {
        HStack(spacing: 8) {
            ComposerDictationButton(
                state: dictationState,
                isEnabled: isDictationEnabled,
                action: onDictationTapped
            )
            ComposerPlanModeButton(isEnabled: $isPlanModeEnabled)
        }
        .lineLimit(1)
    }
}

struct ComposerDictationButton: View {
    var state: DictationState
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbolName)
                .font(.callout.weight(.bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(foregroundStyle)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
                .background(backgroundStyle, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(borderStyle, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var title: String {
        switch state {
        case .idle:
            "听写"
        case .listening:
            "听写中"
        case .denied:
            "未授权"
        case .error:
            "听写错误"
        }
    }

    private var symbolName: String {
        switch state {
        case .idle:
            "mic"
        case .listening:
            "waveform"
        case .denied:
            "mic.slash"
        case .error:
            "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        switch state {
        case .idle:
            ComposerFeatureControlStyle.text
        case .listening:
            ComposerFeatureControlStyle.green
        case .denied, .error:
            ComposerFeatureControlStyle.orange
        }
    }

    private var backgroundStyle: Color {
        switch state {
        case .idle:
            ComposerFeatureControlStyle.panel
        case .listening:
            ComposerFeatureControlStyle.green.opacity(0.16)
        case .denied, .error:
            ComposerFeatureControlStyle.orange.opacity(0.14)
        }
    }

    private var borderStyle: Color {
        switch state {
        case .idle:
            ComposerFeatureControlStyle.separator
        case .listening:
            ComposerFeatureControlStyle.green.opacity(0.36)
        case .denied, .error:
            ComposerFeatureControlStyle.orange.opacity(0.36)
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle:
            "开始听写"
        case .listening:
            "停止听写"
        case .denied:
            "听写权限未授权"
        case .error:
            "听写错误"
        }
    }

    private var accessibilityHint: String {
        state.errorMessage ?? ""
    }
}

struct ComposerPlanModeButton: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Button {
            isEnabled.toggle()
        } label: {
            Label("计划", systemImage: isEnabled ? "checklist.checked" : "list.bullet.rectangle")
                .font(.callout.weight(.bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(foregroundStyle)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
                .background(backgroundStyle, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(borderStyle, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEnabled ? "关闭计划模式" : "开启计划模式")
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
    }

    private var foregroundStyle: Color {
        isEnabled ? ComposerFeatureControlStyle.blue : ComposerFeatureControlStyle.secondaryText
    }

    private var backgroundStyle: Color {
        isEnabled ? ComposerFeatureControlStyle.blue.opacity(0.16) : ComposerFeatureControlStyle.panel
    }

    private var borderStyle: Color {
        isEnabled ? ComposerFeatureControlStyle.blue.opacity(0.36) : ComposerFeatureControlStyle.separator
    }
}

private enum ComposerFeatureControlStyle {
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.105)
    static let separator = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let green = Color(red: 0.18, green: 0.76, blue: 0.42)
    static let orange = Color(red: 1.0, green: 0.45, blue: 0.18)
    static let blue = Color(red: 0.36, green: 0.63, blue: 1.0)
}

#Preview("Composer Feature Controls") {
    VStack(alignment: .leading, spacing: 12) {
        ComposerFeatureControls(
            dictationState: .idle,
            isPlanModeEnabled: .constant(false),
            onDictationTapped: {}
        )
        ComposerFeatureControls(
            dictationState: .listening,
            isPlanModeEnabled: .constant(true),
            onDictationTapped: {}
        )
        ComposerFeatureControls(
            dictationState: .denied,
            isPlanModeEnabled: .constant(false),
            onDictationTapped: {}
        )
        ComposerFeatureControls(
            dictationState: .error("语音识别当前不可用。"),
            isPlanModeEnabled: .constant(true),
            onDictationTapped: {}
        )
    }
    .padding()
    .background(Color(red: 0.055, green: 0.055, blue: 0.055))
    .preferredColorScheme(.dark)
}
