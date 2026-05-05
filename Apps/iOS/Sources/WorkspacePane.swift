import Foundation

enum WorkspacePane: String, CaseIterable, Identifiable {
    case chat
    case automations
    case terminal
    case files
    case context

    var id: String { rawValue }

    static let sidebarPanes: [WorkspacePane] = [.automations]
    static let headerToolPanes: [WorkspacePane] = [.terminal, .files, .context]
    static let sheetPanes: [WorkspacePane] = [.automations, .terminal, .files, .context]

    var title: String {
        switch self {
        case .chat: "聊天"
        case .automations: "自动化"
        case .terminal: "终端"
        case .files: "文件"
        case .context: "上下文"
        }
    }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .automations: "clock.arrow.circlepath"
        case .terminal: "terminal"
        case .files: "folder"
        case .context: "square.stack.3d.up"
        }
    }
}
