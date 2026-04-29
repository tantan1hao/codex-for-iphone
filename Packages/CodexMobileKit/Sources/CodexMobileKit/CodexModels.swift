import Foundation

public struct CodexThread: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var preview: String
    public var cwd: String
    public var status: String
    public var updatedAt: Date?

    public init(id: String, name: String?, preview: String, cwd: String, status: String, updatedAt: Date?) {
        self.id = id
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if !preview.isEmpty { return preview }
        return "Untitled Thread"
    }

    public static func parseListResponse(_ value: JSONValue) -> [CodexThread] {
        guard let data = value.objectValue?["data"]?.arrayValue else { return [] }
        return data.compactMap(parse)
    }

    public static func parseStartOrResumeResponse(_ value: JSONValue) -> CodexThread? {
        guard let thread = value.objectValue?["thread"] else { return nil }
        return parse(thread)
    }

    public static func parse(_ value: JSONValue) -> CodexThread? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue
        else { return nil }
        let updatedAt = object["updatedAt"].flatMap(Self.date)
        return CodexThread(
            id: id,
            name: object["name"]?.stringValue,
            preview: object["preview"]?.stringValue ?? "",
            cwd: object["cwd"]?.stringValue ?? "",
            status: object["status"]?.stringValue ?? "unknown",
            updatedAt: updatedAt
        )
    }

    private static func date(_ value: JSONValue) -> Date? {
        guard case let .number(seconds) = value else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

public struct ConversationItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user
        case assistant
        case reasoning
        case plan
        case command
        case fileChange
        case approval
        case warning
        case error
        case tool
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var status: String?

    public init(id: String, kind: Kind, title: String, body: String = "", status: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
    }
}

public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public var id: JSONRPCID
    public var method: String
    public var threadID: String?
    public var turnID: String?
    public var itemID: String?
    public var title: String
    public var body: String
    public var availableDecisions: [String]

    public init(id: JSONRPCID, method: String, params: JSONValue?) {
        let object = params?.objectValue ?? [:]
        self.id = id
        self.method = method
        self.threadID = object["threadId"]?.stringValue
        self.turnID = object["turnId"]?.stringValue
        self.itemID = object["itemId"]?.stringValue
        self.title = ApprovalRequest.title(method: method, params: object)
        self.body = ApprovalRequest.body(method: method, params: object)
        self.availableDecisions = object["availableDecisions"]?.arrayValue?
            .compactMap(\.stringValue)
            .filter { ["accept", "acceptForSession", "decline", "cancel"].contains($0) } ?? [
                "accept",
                "decline",
                "cancel",
            ]
    }

    public func response(decision: String) -> JSONValue {
        if method == "item/permissions/requestApproval", decision == "accept" {
            return ["scope": "turn", "permissions": requestedPermissions]
        }
        return ["decision": .string(decision)]
    }

    private var requestedPermissions: JSONValue {
        .object([:])
    }

    private static func title(method: String, params: [String: JSONValue]) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            return "Command approval"
        case "item/fileChange/requestApproval":
            return "File change approval"
        case "item/permissions/requestApproval":
            return "Permission request"
        case "item/tool/requestUserInput":
            return "Input requested"
        case "mcpServer/elicitation/request":
            return "Tool request"
        default:
            return "Approval required"
        }
    }

    private static func body(method: String, params: [String: JSONValue]) -> String {
        if let command = params["command"]?.stringValue {
            return command
        }
        if let reason = params["reason"]?.stringValue {
            return reason
        }
        if let message = params["message"]?.stringValue {
            return message
        }
        if let cwd = params["cwd"]?.stringValue {
            return cwd
        }
        return method
    }
}

public struct ConversationState: Equatable, Sendable {
    public var threadID: String?
    public var items: [ConversationItem] = []
    public var isRunning = false
    public var activeApproval: ApprovalRequest?
    public var lastError: String?

    public init(threadID: String? = nil) {
        self.threadID = threadID
    }
}

public enum ConversationReducer {
    public static func state(fromThreadResponse value: JSONValue, fallbackThreadID: String? = nil) -> ConversationState {
        let thread = value.objectValue?["thread"]?.objectValue ?? value.objectValue ?? [:]
        let threadID = thread["id"]?.stringValue ?? fallbackThreadID
        var state = ConversationState(threadID: threadID)
        let turns = thread["turns"]?.arrayValue ?? []
        for turn in turns {
            apply(turn, to: &state)
        }
        return state
    }

    public static func state(fromTurnsListResponse value: JSONValue, threadID: String) -> ConversationState {
        var state = ConversationState(threadID: threadID)
        let turns = value.objectValue?["data"]?.arrayValue ?? []
        for turn in turns.reversed() {
            apply(turn, to: &state)
        }
        return state
    }

    public static func nextCursor(fromTurnsListResponse value: JSONValue) -> String? {
        value.objectValue?["nextCursor"]?.stringValue
    }

    public static func reduce(_ state: inout ConversationState, event: AppServerEvent) {
        switch event {
        case let .serverRequest(id, method, params):
            state.activeApproval = ApprovalRequest(id: id, method: method, params: params)
            let approval = state.activeApproval
            if let approval {
                upsert(
                    &state,
                    item: ConversationItem(
                        id: "approval-\(id.description)",
                        kind: .approval,
                        title: approval.title,
                        body: approval.body,
                        status: "pending"
                    )
                )
            }
        case let .notification(method, params):
            reduceNotification(&state, method: method, params: params)
        case let .disconnected(message):
            state.isRunning = false
            state.lastError = message
        }
    }

    private static func reduceNotification(_ state: inout ConversationState, method: String, params: JSONValue?) {
        let object = params?.objectValue ?? [:]
        switch method {
        case "thread/started":
            if let thread = object["thread"].flatMap(CodexThread.parse) {
                state.threadID = thread.id
            }
        case "turn/started":
            state.isRunning = true
        case "turn/completed":
            state.isRunning = false
        case "serverRequest/resolved":
            state.activeApproval = nil
        case "item/started", "item/completed":
            if let item = object["item"].flatMap(parseItem) {
                upsert(&state, item: item)
            }
        case "item/agentMessage/delta":
            appendDelta(&state, object: object, kind: .assistant, title: "Codex", deltaKey: "delta")
        case "item/plan/delta":
            appendDelta(&state, object: object, kind: .plan, title: "Plan", deltaKey: "delta")
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            appendDelta(&state, object: object, kind: .reasoning, title: "Reasoning", deltaKey: "delta")
        case "item/commandExecution/outputDelta":
            appendDelta(&state, object: object, kind: .command, title: "Command output", deltaKey: "delta")
        case "item/fileChange/patch/updated", "item/fileChange/patchUpdated":
            let id = object["itemId"]?.stringValue ?? UUID().uuidString
            upsert(&state, item: ConversationItem(id: id, kind: .fileChange, title: "File changes", body: "Patch updated", status: "updated"))
        case "error":
            let message = object["error"]?.objectValue?["message"]?.stringValue ?? object["message"]?.stringValue ?? "Codex error"
            state.lastError = message
            upsert(&state, item: ConversationItem(id: UUID().uuidString, kind: .error, title: "Error", body: message))
        case "warning":
            let message = object["message"]?.stringValue ?? "Warning"
            upsert(&state, item: ConversationItem(id: UUID().uuidString, kind: .warning, title: "Warning", body: message))
        default:
            break
        }
    }

    private static func parseItem(_ value: JSONValue) -> ConversationItem? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue,
              let id = object["id"]?.stringValue
        else { return nil }

        switch type {
        case "userMessage":
            let text = object["content"]?.arrayValue?.compactMap { input -> String? in
                guard let object = input.objectValue, object["type"]?.stringValue == "text" else { return nil }
                return object["text"]?.stringValue
            }.joined(separator: "\n") ?? ""
            return ConversationItem(id: id, kind: .user, title: "You", body: text)
        case "agentMessage":
            return ConversationItem(id: id, kind: .assistant, title: "Codex", body: object["text"]?.stringValue ?? "")
        case "reasoning":
            return ConversationItem(id: id, kind: .reasoning, title: "Reasoning", body: joinedStringArrays(object, keys: ["summary", "content"]))
        case "plan":
            return ConversationItem(id: id, kind: .plan, title: "Plan", body: object["text"]?.stringValue ?? "")
        case "commandExecution":
            return ConversationItem(
                id: id,
                kind: .command,
                title: object["command"]?.stringValue ?? "Command",
                body: object["aggregatedOutput"]?.stringValue ?? "",
                status: object["status"]?.stringValue
            )
        case "fileChange":
            return ConversationItem(id: id, kind: .fileChange, title: "File changes", body: "Review proposed edits", status: object["status"]?.stringValue)
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return ConversationItem(id: id, kind: .tool, title: type, body: object["tool"]?.stringValue ?? "", status: object["status"]?.stringValue)
        default:
            return ConversationItem(id: id, kind: .tool, title: type)
        }
    }

    private static func apply(_ turn: JSONValue, to state: inout ConversationState) {
        guard let turnObject = turn.objectValue else { return }
        if turnObject["status"]?.stringValue == "inProgress" {
            state.isRunning = true
        }
        for itemValue in turnObject["items"]?.arrayValue ?? [] {
            if let item = parseItem(itemValue) {
                upsert(&state, item: item)
            }
        }
        if let errorMessage = turnObject["error"]?.objectValue?["message"]?.stringValue {
            state.lastError = errorMessage
            upsert(
                &state,
                item: ConversationItem(
                    id: "turn-error-\(turnObject["id"]?.stringValue ?? UUID().uuidString)",
                    kind: .error,
                    title: "Error",
                    body: errorMessage
                )
            )
        }
    }

    private static func appendDelta(
        _ state: inout ConversationState,
        object: [String: JSONValue],
        kind: ConversationItem.Kind,
        title: String,
        deltaKey: String
    ) {
        guard let itemID = object["itemId"]?.stringValue,
              let delta = object[deltaKey]?.stringValue
        else { return }
        if let index = state.items.firstIndex(where: { $0.id == itemID }) {
            state.items[index].body += delta
        } else {
            state.items.append(ConversationItem(id: itemID, kind: kind, title: title, body: delta))
        }
    }

    private static func upsert(_ state: inout ConversationState, item: ConversationItem) {
        if let index = state.items.firstIndex(where: { $0.id == item.id }) {
            state.items[index] = item
        } else {
            state.items.append(item)
        }
    }

    private static func joinedStringArrays(_ object: [String: JSONValue], keys: [String]) -> String {
        keys.flatMap { key in
            object[key]?.arrayValue?.compactMap(\.stringValue) ?? []
        }.joined(separator: "\n")
    }
}
