import Foundation

public struct CodexModelOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var model: String
    public var displayName: String
    public var defaultReasoningEffort: String?
    public var supportedReasoningEfforts: [String]
    public var additionalSpeedTiers: [String]
    public var isDefault: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        defaultReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String] = [],
        additionalSpeedTiers: [String] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.additionalSpeedTiers = additionalSpeedTiers
        self.isDefault = isDefault
    }

    public static let fallback = CodexModelOption(
        id: "gpt-5.5",
        model: "gpt-5.5",
        displayName: "GPT-5.5",
        defaultReasoningEffort: "xhigh",
        supportedReasoningEfforts: ["medium", "high", "xhigh"],
        additionalSpeedTiers: ["fast"],
        isDefault: true
    )

    public static func parseListResponse(_ value: JSONValue) -> [CodexModelOption] {
        guard let data = value.objectValue?["data"]?.arrayValue else { return [] }
        return data.compactMap(parse)
    }

    public static func parse(_ value: JSONValue) -> CodexModelOption? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let model = object["model"]?.stringValue
        else { return nil }
        let displayName = object["displayName"]?.stringValue ?? model
        let effortOptions = object["supportedReasoningEfforts"]?.arrayValue?.compactMap { option in
            option.objectValue?["reasoningEffort"]?.stringValue
        } ?? []
        let additionalSpeedTiers = object["additionalSpeedTiers"]?.arrayValue?.compactMap(\.stringValue)
            ?? object["additional_speed_tiers"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        return CodexModelOption(
            id: id,
            model: model,
            displayName: displayName,
            defaultReasoningEffort: object["defaultReasoningEffort"]?.stringValue,
            supportedReasoningEfforts: effortOptions,
            additionalSpeedTiers: additionalSpeedTiers,
            isDefault: object["isDefault"]?.boolValue ?? false
        )
    }
}

public enum CodexServiceTier: String, CaseIterable, Identifiable, Sendable {
    case standard
    case fast

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .standard: "标准"
        case .fast: "快速"
        }
    }

    public var compactTitle: String {
        switch self {
        case .standard: "标准"
        case .fast: "快速"
        }
    }

    public static func fromConfig(_ value: JSONValue?) -> CodexServiceTier? {
        guard let rawValue = value?.stringValue else { return nil }
        return CodexServiceTier(rawValue: rawValue)
    }
}

public enum CodexPermissionPreset: String, CaseIterable, Identifiable, Sendable {
    case readOnly
    case workspaceWrite
    case fullAccess

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .readOnly: "只读"
        case .workspaceWrite: "工作区写入"
        case .fullAccess: "完全访问权限"
        }
    }

    public var compactTitle: String {
        switch self {
        case .readOnly: "只读"
        case .workspaceWrite: "读写"
        case .fullAccess: "全权"
        }
    }

    public var symbolName: String {
        switch self {
        case .readOnly: "eye"
        case .workspaceWrite: "square.and.pencil"
        case .fullAccess: "exclamationmark.shield"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly: "命令和写入会请求确认"
        case .workspaceWrite: "允许工作区写入，危险操作请求确认"
        case .fullAccess: "不请求审批，允许完整本机访问"
        }
    }

    public var approvalPolicy: JSONValue {
        switch self {
        case .readOnly, .workspaceWrite:
            .string("on-request")
        case .fullAccess:
            .string("never")
        }
    }

    public var sandboxMode: JSONValue {
        switch self {
        case .readOnly:
            .string("read-only")
        case .workspaceWrite:
            .string("workspace-write")
        case .fullAccess:
            .string("danger-full-access")
        }
    }

    public func turnSandboxPolicy(cwd: String) -> JSONValue {
        switch self {
        case .readOnly:
            [
                "type": "readOnly",
                "networkAccess": false,
            ]
        case .workspaceWrite:
            [
                "type": "workspaceWrite",
                "writableRoots": [.string(cwd)],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            ]
        case .fullAccess:
            [
                "type": "dangerFullAccess",
            ]
        }
    }

    public static func fromConfig(approvalPolicy: JSONValue?, sandboxMode: JSONValue?) -> CodexPermissionPreset {
        if sandboxMode?.stringValue == "danger-full-access" || approvalPolicy?.stringValue == "never" {
            return .fullAccess
        }
        if sandboxMode?.stringValue == "read-only" {
            return .readOnly
        }
        return .workspaceWrite
    }
}

public struct CodexSessionSettings: Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var permissionPreset: CodexPermissionPreset
    public var serviceTier: CodexServiceTier

    public init(
        model: String?,
        reasoningEffort: String?,
        permissionPreset: CodexPermissionPreset,
        serviceTier: CodexServiceTier = .standard
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissionPreset = permissionPreset
        self.serviceTier = serviceTier
    }
}
