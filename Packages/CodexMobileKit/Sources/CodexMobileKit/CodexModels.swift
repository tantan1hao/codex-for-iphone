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

public struct ApprovalDecisionOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var value: JSONValue
    public var isAffirmative: Bool

    public init(id: String, title: String, value: JSONValue, isAffirmative: Bool) {
        self.id = id
        self.title = title
        self.value = value
        self.isAffirmative = isAffirmative
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
    public var decisionOptions: [ApprovalDecisionOption]
    public var requestedPermissions: JSONValue

    public init(id: JSONRPCID, method: String, params: JSONValue?) {
        let object = params?.objectValue ?? [:]
        self.id = id
        self.method = method
        self.threadID = object["threadId"]?.stringValue
        self.turnID = object["turnId"]?.stringValue
        self.itemID = object["itemId"]?.stringValue
        self.title = ApprovalRequest.title(method: method, params: object)
        self.body = ApprovalRequest.body(method: method, params: object)
        self.requestedPermissions = object["permissions"] ?? .object([:])
        self.decisionOptions = ApprovalRequest.decisionOptions(method: method, params: object)
        self.availableDecisions = decisionOptions.map(\.id)
    }

    public func response(decision option: ApprovalDecisionOption) -> JSONValue {
        if method == "item/permissions/requestApproval" {
            let permissions: JSONValue = option.isAffirmative ? requestedPermissions : .object([:])
            let scope: JSONValue = option.id == "acceptForSession" ? "session" : "turn"
            return ["scope": scope, "permissions": permissions]
        }
        return ["decision": option.value]
    }

    public func response(decision: String) -> JSONValue {
        let option = decisionOptions.first { $0.id == decision } ?? ApprovalRequest.fallbackDecisionOption(id: decision)
        return response(decision: option)
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

    private static func decisionOptions(method: String, params: [String: JSONValue]) -> [ApprovalDecisionOption] {
        let advertised = params["availableDecisions"]?.arrayValue ?? []
        let parsed = advertised.enumerated().compactMap { index, value in
            decisionOption(value: value, index: index)
        }
        if !parsed.isEmpty {
            return parsed
        }
        return ["accept", "decline", "cancel"].enumerated().map { index, decision in
            decisionOption(value: .string(decision), index: index) ?? fallbackDecisionOption(id: decision)
        }
    }

    private static func decisionOption(value: JSONValue, index: Int) -> ApprovalDecisionOption? {
        if let decision = value.stringValue {
            guard ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else { return nil }
            return fallbackDecisionOption(id: decision)
        }
        guard let object = value.objectValue,
              let key = object.keys.sorted().first,
              ["acceptWithExecpolicyAmendment", "applyNetworkPolicyAmendment"].contains(key)
        else { return nil }
        return ApprovalDecisionOption(
            id: "\(key)-\(index)",
            title: decisionTitle(key),
            value: value,
            isAffirmative: true
        )
    }

    private static func fallbackDecisionOption(id: String) -> ApprovalDecisionOption {
        ApprovalDecisionOption(
            id: id,
            title: decisionTitle(id),
            value: .string(id),
            isAffirmative: ["accept", "acceptForSession"].contains(id)
        )
    }

    private static func decisionTitle(_ decision: String) -> String {
        switch decision {
        case "accept": "批准"
        case "acceptForSession": "本会话批准"
        case "acceptWithExecpolicyAmendment": "批准并记住"
        case "applyNetworkPolicyAmendment": "应用网络规则"
        case "decline": "拒绝"
        case "cancel": "取消"
        default: decision
        }
    }
}

public struct ConversationState: Equatable, Sendable {
    public var threadID: String?
    public var activeTurnID: String?
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

    public static func merging(existing: ConversationState, incoming: ConversationState) -> ConversationState {
        guard incoming.threadID == nil || existing.threadID == nil || incoming.threadID == existing.threadID else {
            return existing
        }
        var state = existing
        if let threadID = incoming.threadID {
            state.threadID = threadID
        }
        if !incoming.items.isEmpty {
            if let replacementRange = matchingRange(in: state.items, pattern: incoming.items) {
                state.items.replaceSubrange(replacementRange, with: incoming.items)
            } else if let replacementRange = tailRefreshReplacementRange(in: state.items, incoming: incoming.items) {
                state.items.replaceSubrange(replacementRange, with: incoming.items)
            } else {
                for item in incoming.items {
                    upsertOrAppend(&state.items, item: item)
                }
            }
            state.items = collapsedAdjacentDuplicates(state.items)
        }
        state.isRunning = incoming.isRunning
        state.activeTurnID = incoming.activeTurnID ?? (incoming.isRunning ? state.activeTurnID : nil)
        state.activeApproval = incoming.activeApproval ?? state.activeApproval
        state.lastError = incoming.lastError ?? state.lastError
        return state
    }

    public static func prependingOlder(existing: ConversationState, older: ConversationState) -> ConversationState {
        guard older.threadID == nil || existing.threadID == nil || older.threadID == existing.threadID else {
            return existing
        }
        var state = existing
        var items = older.items
        for item in existing.items {
            upsertOrAppend(&items, item: item)
        }
        state.items = collapsedAdjacentDuplicates(items)
        state.isRunning = existing.isRunning || older.isRunning
        state.activeTurnID = existing.activeTurnID ?? older.activeTurnID
        if !state.isRunning {
            state.activeTurnID = nil
        }
        state.activeApproval = existing.activeApproval ?? older.activeApproval
        state.lastError = existing.lastError ?? older.lastError
        return state
    }

    public static func normalized(_ state: ConversationState) -> ConversationState {
        var state = state
        state.items = collapsedAdjacentDuplicates(state.items)
        return state
    }

    public static func reduce(_ state: inout ConversationState, event: AppServerEvent) {
        switch event {
        case let .serverRequest(id, method, params):
            state.activeApproval = ApprovalRequest(id: id, method: method, params: params)
            state.activeTurnID = state.activeApproval?.turnID ?? state.activeTurnID
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
            state.activeTurnID = nil
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
            state.activeTurnID = object["turnId"]?.stringValue
                ?? object["turn"]?.objectValue?["id"]?.stringValue
                ?? state.activeTurnID
        case "turn/completed":
            state.isRunning = false
            state.activeTurnID = nil
            state.activeApproval = nil
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
            state.activeTurnID = turnObject["id"]?.stringValue ?? state.activeTurnID
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

    private static func upsertOrAppend(_ items: inout [ConversationItem], item: ConversationItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
            return
        }
        if let last = items.indices.last,
           areSemanticDuplicates(items[last], item)
        {
            items[last] = item
            return
        }
        items.append(item)
    }

    private static func matchingRange(in existing: [ConversationItem], pattern incoming: [ConversationItem]) -> Range<Int>? {
        guard !incoming.isEmpty, existing.count >= incoming.count else { return nil }
        let incomingKeys = incoming.map(semanticFingerprint)
        guard incomingKeys.allSatisfy({ $0 != nil }) else { return nil }
        for start in stride(from: existing.count - incoming.count, through: 0, by: -1) {
            var matches = true
            for offset in incoming.indices {
                if semanticFingerprint(existing[start + offset]) != incomingKeys[offset] {
                    matches = false
                    break
                }
            }
            if matches {
                return start..<(start + incoming.count)
            }
        }
        return nil
    }

    private static func tailRefreshReplacementRange(
        in existing: [ConversationItem],
        incoming: [ConversationItem]
    ) -> Range<Int>? {
        guard !incoming.isEmpty,
              let firstIncomingKey = semanticFingerprint(incoming[0])
        else { return nil }

        let searchWindow = max(incoming.count * 3, 8)
        let lowerBound = max(0, existing.count - searchWindow)
        guard lowerBound < existing.count else { return nil }

        for start in stride(from: existing.count - 1, through: lowerBound, by: -1) {
            guard semanticFingerprint(existing[start]) == firstIncomingKey else { continue }
            return start..<existing.count
        }
        return nil
    }

    private static func collapsedAdjacentDuplicates(_ items: [ConversationItem]) -> [ConversationItem] {
        var result: [ConversationItem] = []
        for item in items {
            if let last = result.indices.last,
               areSemanticDuplicates(result[last], item)
            {
                result[last] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func areSemanticDuplicates(_ lhs: ConversationItem, _ rhs: ConversationItem) -> Bool {
        guard let lhsKey = semanticFingerprint(lhs),
              let rhsKey = semanticFingerprint(rhs)
        else { return false }
        return lhsKey == rhsKey
    }

    private static func semanticFingerprint(_ item: ConversationItem) -> String? {
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        switch item.kind {
        case .user, .assistant, .reasoning, .plan, .command, .tool, .warning, .error:
            return "\(item.kind.rawValue)\u{1f}\(item.title)\u{1f}\(body)"
        case .fileChange, .approval:
            return nil
        }
    }

    private static func joinedStringArrays(_ object: [String: JSONValue], keys: [String]) -> String {
        keys.flatMap { key in
            object[key]?.arrayValue?.compactMap(\.stringValue) ?? []
        }.joined(separator: "\n")
    }
}
