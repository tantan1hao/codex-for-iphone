import SwiftUI
import UIKit

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum CodexTheme {
    static let appBackground = dynamic(
        light: rgb(0.956, 0.962, 0.970),
        dark: rgb(0.055, 0.055, 0.055)
    )
    static let sidebarTop = dynamic(
        light: rgb(0.925, 0.952, 0.990),
        dark: rgb(0.160, 0.140, 0.240)
    )
    static let sidebarBottom = dynamic(
        light: rgb(0.980, 0.984, 0.990),
        dark: rgb(0.100, 0.100, 0.120)
    )
    static let panel = dynamic(
        light: rgb(1.000, 1.000, 1.000),
        dark: rgb(0.105, 0.105, 0.105)
    )
    static let panelRaised = dynamic(
        light: rgb(0.990, 0.992, 0.996),
        dark: rgb(0.135, 0.135, 0.135)
    )
    static let selected = dynamic(
        light: UIColor(red: 0.000, green: 0.260, blue: 0.620, alpha: 0.100),
        dark: UIColor(white: 1.000, alpha: 0.120)
    )
    static let separator = dynamic(
        light: UIColor(white: 0.000, alpha: 0.100),
        dark: UIColor(white: 1.000, alpha: 0.070)
    )
    static let text = dynamic(
        light: UIColor(white: 0.070, alpha: 0.940),
        dark: UIColor(white: 1.000, alpha: 0.920)
    )
    static let secondaryText = dynamic(
        light: UIColor(white: 0.120, alpha: 0.620),
        dark: UIColor(white: 1.000, alpha: 0.550)
    )
    static let tertiaryText = dynamic(
        light: UIColor(white: 0.140, alpha: 0.420),
        dark: UIColor(white: 1.000, alpha: 0.340)
    )
    static let userBubble = dynamic(
        light: UIColor(red: 0.000, green: 0.320, blue: 0.820, alpha: 0.100),
        dark: UIColor(white: 1.000, alpha: 0.080)
    )
    static let sendButtonFill = dynamic(
        light: UIColor(white: 0.100, alpha: 1.000),
        dark: UIColor(white: 1.000, alpha: 0.920)
    )
    static let onSendButton = dynamic(
        light: UIColor(white: 1.000, alpha: 1.000),
        dark: UIColor(white: 0.000, alpha: 0.920)
    )
    static let green = dynamic(
        light: rgb(0.050, 0.500, 0.220),
        dark: rgb(0.180, 0.760, 0.420)
    )
    static let orange = dynamic(
        light: rgb(0.780, 0.300, 0.060),
        dark: rgb(1.000, 0.450, 0.180)
    )
    static let blue = dynamic(
        light: rgb(0.000, 0.360, 0.820),
        dark: rgb(0.360, 0.630, 1.000)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
