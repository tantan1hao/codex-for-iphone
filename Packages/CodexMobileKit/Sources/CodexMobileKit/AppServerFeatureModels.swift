import Foundation

public extension JSONValue {
    var numberValue: Double? {
        switch self {
        case let .number(value):
            return value
        case let .string(value):
            return Double(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        guard let numberValue else { return nil }
        return Int(numberValue)
    }
}

public struct CodexCollaborationMode: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var isDefault: Bool
    public var isEnabled: Bool
    public var raw: JSONValue

    public init(
        id: String,
        title: String,
        description: String? = nil,
        isDefault: Bool = false,
        isEnabled: Bool = true,
        raw: JSONValue = .object([:])
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.isDefault = isDefault
        self.isEnabled = isEnabled
        self.raw = raw
    }

    public static func parseListResponse(_ value: JSONValue) -> [CodexCollaborationMode] {
        CodexFeatureParsing.array(value, keys: ["data", "modes", "items", "collaborationModes"])
            .compactMap(parse)
    }

    public static func parse(_ value: JSONValue) -> CodexCollaborationMode? {
        if let string = value.stringValue {
            return CodexCollaborationMode(id: string, title: string, raw: value)
        }
        guard let object = value.objectValue else { return nil }
        let id = CodexFeatureParsing.string(object, keys: ["id", "mode", "name", "key"]) ?? ""
        let title = CodexFeatureParsing.string(object, keys: ["title", "label", "displayName", "name"]) ?? id
        return CodexCollaborationMode(
            id: id,
            title: title,
            description: CodexFeatureParsing.string(object, keys: ["description", "summary"]),
            isDefault: CodexFeatureParsing.bool(object, keys: ["isDefault", "default"]) ?? false,
            isEnabled: CodexFeatureParsing.bool(object, keys: ["isEnabled", "enabled", "available"]) ?? true,
            raw: value
        )
    }
}

public struct CodexTokenUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var totalTokens: Int
    public var tokenLimit: Int?
    public var remainingTokens: Int?
    public var reportedPercentRemaining: Double?
    public var raw: JSONValue

    public init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        totalTokens: Int = 0,
        tokenLimit: Int? = nil,
        remainingTokens: Int? = nil,
        reportedPercentRemaining: Double? = nil,
        raw: JSONValue = .object([:])
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.tokenLimit = tokenLimit
        self.remainingTokens = remainingTokens
        self.reportedPercentRemaining = reportedPercentRemaining
        self.raw = raw
    }

    public var percentRemaining: Double? {
        percentRemaining(fallbackTokenLimit: nil)
    }

    public func percentRemaining(fallbackTokenLimit: Int?) -> Double? {
        if let reportedPercentRemaining {
            return Self.normalizedPercent(reportedPercentRemaining)
        }
        let effectiveTokenLimit = tokenLimit ?? fallbackTokenLimit
        guard let effectiveTokenLimit, effectiveTokenLimit > 0 else { return nil }
        if let remainingTokens {
            return Self.clampedPercent(Double(remainingTokens) / Double(effectiveTokenLimit) * 100)
        }
        let remaining = effectiveTokenLimit - totalTokens
        return Self.clampedPercent(Double(remaining) / Double(effectiveTokenLimit) * 100)
    }

    public static func parse(_ value: JSONValue) -> CodexTokenUsage? {
        guard let object = CodexFeatureParsing.object(value, unwrapping: [
            "usage", "tokenUsage", "token_usage", "tokens", "info",
            "contextUsage", "context_usage", "data",
        ]) else {
            return nil
        }
        let tokenLimit = CodexFeatureParsing.int(object, keys: [
            "tokenLimit", "token_limit", "contextWindow", "context_window",
            "modelContextWindow", "model_context_window",
            "contextLimit", "context_limit", "maxTokens", "max_tokens",
            "maxContextTokens", "max_context_tokens", "limit",
        ])
        if let totalObject = firstObject(
            in: object,
            keys: ["total", "totalTokenUsage", "total_token_usage", "totalUsage", "total_usage"]
        ),
            let usage = parseBreakdown(totalObject, tokenLimit: tokenLimit, raw: value)
        {
            return usage
        }
        return parseBreakdown(object, tokenLimit: tokenLimit, raw: value)
    }

    public static func find(in value: JSONValue) -> CodexTokenUsage? {
        if let usage = parse(value) {
            return usage
        }
        switch value {
        case let .object(object):
            let preferredKeys = [
                "usage", "tokenUsage", "token_usage", "tokens",
                "contextUsage", "context_usage", "context", "info",
                "metrics", "stats", "data", "turn", "thread", "response",
            ]
            for key in preferredKeys {
                if let nested = object[key], let usage = find(in: nested) {
                    return usage
                }
            }
            for (key, nested) in object where !preferredKeys.contains(key) {
                if let usage = find(in: nested) {
                    return usage
                }
            }
        case let .array(values):
            for value in values {
                if let usage = find(in: value) {
                    return usage
                }
            }
        case .null, .bool, .number, .string:
            break
        }
        return nil
    }

    private static func parseBreakdown(
        _ object: [String: JSONValue],
        tokenLimit: Int?,
        raw: JSONValue
    ) -> CodexTokenUsage? {
        let inputTokens = CodexFeatureParsing.int(object, keys: ["inputTokens", "input_tokens", "promptTokens", "prompt_tokens"])
        let cachedInputTokens = CodexFeatureParsing.int(object, keys: ["cachedInputTokens", "cached_input_tokens", "cachedTokens", "cached_tokens"])
        let outputTokens = CodexFeatureParsing.int(object, keys: ["outputTokens", "output_tokens", "completionTokens", "completion_tokens"])
        let reasoningOutputTokens = CodexFeatureParsing.int(object, keys: ["reasoningOutputTokens", "reasoning_output_tokens", "reasoningTokens", "reasoning_tokens"])
        let explicitTotalTokens = CodexFeatureParsing.int(object, keys: [
            "totalTokens", "total_tokens", "total", "tokens",
            "usedTokens", "used_tokens", "tokensUsed", "tokens_used",
            "contextTokens", "context_tokens", "tokensInContext", "tokens_in_context",
        ])
        let localTokenLimit = CodexFeatureParsing.int(object, keys: [
            "tokenLimit", "token_limit", "contextWindow", "context_window",
            "modelContextWindow", "model_context_window",
            "contextLimit", "context_limit", "maxTokens", "max_tokens",
            "maxContextTokens", "max_context_tokens", "limit",
        ]) ?? tokenLimit
        let remainingTokens = CodexFeatureParsing.int(object, keys: [
            "remainingTokens", "remaining_tokens", "tokensRemaining", "tokens_remaining",
            "remaining", "remainingContextTokens", "remaining_context_tokens",
        ])
        let reportedPercentRemaining = CodexFeatureParsing.double(object, keys: [
            "percentRemaining", "percent_remaining", "remainingPercent", "remaining_percent",
            "remainingPct", "remaining_pct",
        ])
        let hasUsageSignal = [
            inputTokens,
            cachedInputTokens,
            outputTokens,
            reasoningOutputTokens,
            explicitTotalTokens,
            localTokenLimit,
            remainingTokens,
        ].contains { $0 != nil } || reportedPercentRemaining != nil
        guard hasUsageSignal else { return nil }

        let totalTokens = explicitTotalTokens
            ?? [inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens].compactMap { $0 }.reduce(0, +)
        return CodexTokenUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens,
            tokenLimit: localTokenLimit,
            remainingTokens: remainingTokens,
            reportedPercentRemaining: reportedPercentRemaining,
            raw: raw
        )
    }

    private static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        for key in keys {
            if let nested = object[key]?.objectValue {
                return nested
            }
        }
        return nil
    }

    private static func normalizedPercent(_ value: Double) -> Double {
        clampedPercent(value <= 1 ? value * 100 : value)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

public struct CodexAutomationTaskSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var schedule: String?
    public var prompt: String?
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var isEnabled: Bool?
    public var raw: JSONValue

    public init(
        id: String,
        title: String,
        status: String = "unknown",
        schedule: String? = nil,
        prompt: String? = nil,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        isEnabled: Bool? = nil,
        raw: JSONValue = .object([:])
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.schedule = schedule
        self.prompt = prompt
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
        self.raw = raw
    }

    public static func parseListResponse(_ value: JSONValue) -> [CodexAutomationTaskSummary] {
        CodexFeatureParsing.array(value, keys: ["data", "tasks", "items", "automations", "automationTasks", "automation_tasks"])
            .compactMap(parse)
    }

    public static func parseGetResponse(_ value: JSONValue) -> CodexAutomationTaskSummary? {
        if let task = value.objectValue?["task"] {
            return parse(task)
        }
        if let automation = value.objectValue?["automation"] {
            return parse(automation)
        }
        if let data = value.objectValue?["data"] {
            return parse(data)
        }
        return parse(value)
    }

    public static func parse(_ value: JSONValue) -> CodexAutomationTaskSummary? {
        guard let object = value.objectValue else { return nil }
        let id = CodexFeatureParsing.string(object, keys: [
            "id", "taskId", "taskID", "task_id",
            "automationId", "automationID", "automation_id", "key",
        ]) ?? ""
        let title = CodexFeatureParsing.string(object, keys: ["title", "name", "displayName", "label", "summary"]) ?? id
        return CodexAutomationTaskSummary(
            id: id,
            title: title,
            status: CodexFeatureParsing.string(object, keys: ["status", "state", "runStatus", "run_status"]) ?? "unknown",
            schedule: CodexFeatureParsing.string(object, keys: [
                "schedule", "scheduleDescription", "schedule_description", "cron", "cadence", "rrule",
            ]),
            prompt: CodexFeatureParsing.string(object, keys: ["prompt", "input", "instructions", "instruction", "description"]),
            nextRunAt: CodexFeatureParsing.date(object, keys: ["nextRunAt", "next_run_at", "nextRun", "next_run"]),
            lastRunAt: CodexFeatureParsing.date(object, keys: ["lastRunAt", "last_run_at", "lastRun", "last_run"]),
            createdAt: CodexFeatureParsing.date(object, keys: ["createdAt", "created_at"]),
            updatedAt: CodexFeatureParsing.date(object, keys: ["updatedAt", "updated_at"]),
            isEnabled: CodexFeatureParsing.bool(object, keys: ["isEnabled", "is_enabled", "enabled", "active"]),
            raw: value
        )
    }
}

public struct CodexRemoteFileEntry: Identifiable, Equatable, Sendable {
    public var id: String { path.isEmpty ? name : path }

    public var name: String
    public var path: String
    public var kind: String?
    public var size: Int?
    public var mimeType: String?
    public var modifiedAt: Date?
    public var isHidden: Bool
    public var directory: Bool?
    public var image: Bool?
    public var raw: JSONValue

    public init(
        name: String,
        path: String,
        kind: String? = nil,
        size: Int? = nil,
        mimeType: String? = nil,
        modifiedAt: Date? = nil,
        isHidden: Bool = false,
        directory: Bool? = nil,
        image: Bool? = nil,
        raw: JSONValue = .object([:])
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.mimeType = mimeType
        self.modifiedAt = modifiedAt
        self.isHidden = isHidden
        self.directory = directory
        self.image = image
        self.raw = raw
    }

    public var isDirectory: Bool {
        if let directory { return directory }
        if let kind {
            let normalized = kind.lowercased()
            if ["directory", "dir", "folder"].contains(normalized) {
                return true
            }
        }
        return mimeType == "inode/directory" || path.hasSuffix("/")
    }

    public var isImage: Bool {
        if let image { return image }
        if isDirectory { return false }
        if let mimeType, mimeType.lowercased().hasPrefix("image/") {
            return true
        }
        return Self.imageExtensions.contains(fileExtension.lowercased())
    }

    public static func parseListResponse(_ value: JSONValue) -> [CodexRemoteFileEntry] {
        CodexFeatureParsing.array(value, keys: ["data", "entries", "items", "files"])
            .compactMap(parse)
    }

    public static func parse(_ value: JSONValue) -> CodexRemoteFileEntry? {
        if let path = value.stringValue {
            return CodexRemoteFileEntry(name: Self.name(fromPath: path), path: path, raw: value)
        }
        guard let object = CodexFeatureParsing.object(value, unwrapping: ["entry", "metadata", "file", "data"]) else {
            return nil
        }
        let path = CodexFeatureParsing.string(object, keys: ["path", "fullPath", "uri"]) ?? ""
        let name = CodexFeatureParsing.string(object, keys: ["name", "basename"]) ?? Self.name(fromPath: path)
        return CodexRemoteFileEntry(
            name: name,
            path: path,
            kind: CodexFeatureParsing.string(object, keys: ["kind", "type", "fileType"]),
            size: CodexFeatureParsing.int(object, keys: ["size", "byteLength", "bytes"]),
            mimeType: CodexFeatureParsing.string(object, keys: ["mimeType", "mime", "contentType"]),
            modifiedAt: CodexFeatureParsing.date(object, keys: ["modifiedAt", "mtime", "updatedAt", "modified_at"]),
            isHidden: CodexFeatureParsing.bool(object, keys: ["isHidden", "hidden"]) ?? name.hasPrefix("."),
            directory: CodexFeatureParsing.bool(object, keys: ["isDirectory", "directory"]),
            image: CodexFeatureParsing.bool(object, keys: ["isImage", "image"]),
            raw: value
        )
    }

    private var fileExtension: String {
        let candidate = path.isEmpty ? name : path
        return URL(fileURLWithPath: candidate).pathExtension
    }

    private static let imageExtensions: Set<String> = [
        "apng", "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
    ]

    private static func name(fromPath path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

public struct CodexRemoteFileContent: Equatable, Sendable {
    public var path: String
    public var text: String?
    public var data: Data?
    public var encoding: String?
    public var mimeType: String?
    public var size: Int?
    public var modifiedAt: Date?
    public var isBase64Encoded: Bool
    public var raw: JSONValue

    public init(
        path: String,
        text: String? = nil,
        data: Data? = nil,
        encoding: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        modifiedAt: Date? = nil,
        isBase64Encoded: Bool = false,
        raw: JSONValue = .object([:])
    ) {
        self.path = path
        self.text = text
        self.data = data
        self.encoding = encoding
        self.mimeType = mimeType
        self.size = size
        self.modifiedAt = modifiedAt
        self.isBase64Encoded = isBase64Encoded
        self.raw = raw
    }

    public var decodedText: String? {
        if let text { return text }
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func parse(_ value: JSONValue) -> CodexRemoteFileContent? {
        if let text = value.stringValue {
            return CodexRemoteFileContent(
                path: "",
                text: text,
                data: Data(text.utf8),
                size: Data(text.utf8).count,
                raw: value
            )
        }
        guard let object = CodexFeatureParsing.object(value, unwrapping: ["file", "content", "data"]) else {
            return nil
        }
        let path = CodexFeatureParsing.string(object, keys: ["path", "fullPath", "uri"]) ?? ""
        let encoding = CodexFeatureParsing.string(object, keys: ["encoding", "contentEncoding"])
        let hasBase64Encoding = encoding?.localizedCaseInsensitiveContains("base64") ?? false
        let hasBase64Field = object["base64"]?.stringValue != nil
        let explicitBase64 = CodexFeatureParsing.bool(object, keys: ["isBase64", "base64Encoded"])
        let isBase64Encoded = explicitBase64 ?? (hasBase64Encoding || hasBase64Field)
        let rawContent = CodexFeatureParsing.string(object, keys: ["content", "text", "data", "base64"])
        let decodedData = Self.data(from: rawContent, isBase64Encoded: isBase64Encoded)
        let text = isBase64Encoded ? decodedData.flatMap { String(data: $0, encoding: .utf8) } : rawContent
        let size = CodexFeatureParsing.int(object, keys: ["size", "byteLength", "bytes"]) ?? decodedData?.count ?? text.map { Data($0.utf8).count }

        return CodexRemoteFileContent(
            path: path,
            text: text,
            data: decodedData,
            encoding: encoding,
            mimeType: CodexFeatureParsing.string(object, keys: ["mimeType", "mime", "contentType"]),
            size: size,
            modifiedAt: CodexFeatureParsing.date(object, keys: ["modifiedAt", "mtime", "updatedAt", "modified_at"]),
            isBase64Encoded: isBase64Encoded,
            raw: value
        )
    }

    private static func data(from content: String?, isBase64Encoded: Bool) -> Data? {
        guard let content else { return nil }
        if isBase64Encoded {
            return Data(base64Encoded: content)
        }
        return Data(content.utf8)
    }
}

public struct CodexCommandExecRequest: Equatable, Sendable {
    public var command: String
    public var cwd: String?
    public var args: [String]
    public var env: [String: String]
    public var stdin: String?
    public var cols: Int?
    public var rows: Int?
    public var timeoutSeconds: Double?

    public init(
        command: String,
        cwd: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        stdin: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        timeoutSeconds: Double? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.args = args
        self.env = env
        self.stdin = stdin
        self.cols = cols
        self.rows = rows
        self.timeoutSeconds = timeoutSeconds
    }

    public var jsonValue: JSONValue {
        var params: [String: JSONValue] = ["command": .string(command)]
        if let cwd {
            params["cwd"] = .string(cwd)
        }
        if !args.isEmpty {
            params["args"] = .array(args.map { .string($0) })
        }
        if !env.isEmpty {
            params["env"] = .object(env.mapValues { .string($0) })
        }
        if let stdin {
            params["stdin"] = .string(stdin)
        }
        if let cols {
            params["cols"] = .number(Double(cols))
        }
        if let rows {
            params["rows"] = .number(Double(rows))
        }
        if let timeoutSeconds {
            params["timeoutSeconds"] = .number(timeoutSeconds)
        }
        return .object(params)
    }
}

public struct CodexCommandExecResult: Equatable, Sendable {
    public var processID: String
    public var status: String
    public var pid: Int?
    public var exitCode: Int?
    public var signal: String?
    public var command: String?
    public var cwd: String?
    public var output: String?
    public var stderr: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var raw: JSONValue

    public init(
        processID: String,
        status: String = "unknown",
        pid: Int? = nil,
        exitCode: Int? = nil,
        signal: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        output: String? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        raw: JSONValue = .object([:])
    ) {
        self.processID = processID
        self.status = status
        self.pid = pid
        self.exitCode = exitCode
        self.signal = signal
        self.command = command
        self.cwd = cwd
        self.output = output
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.raw = raw
    }

    public static func parse(_ value: JSONValue) -> CodexCommandExecResult? {
        guard let object = CodexFeatureParsing.object(value, unwrapping: ["process", "result", "data"]) else {
            return nil
        }
        let processID = CodexFeatureParsing.string(object, keys: ["processId", "processID", "id"]) ?? ""
        return CodexCommandExecResult(
            processID: processID,
            status: CodexFeatureParsing.string(object, keys: ["status", "state"]) ?? "unknown",
            pid: CodexFeatureParsing.int(object, keys: ["pid"]),
            exitCode: CodexFeatureParsing.int(object, keys: ["exitCode", "exit_code", "code"]),
            signal: CodexFeatureParsing.string(object, keys: ["signal"]),
            command: CodexFeatureParsing.string(object, keys: ["command"]),
            cwd: CodexFeatureParsing.string(object, keys: ["cwd"]),
            output: CodexFeatureParsing.string(object, keys: ["output", "stdout", "aggregatedOutput"]),
            stderr: CodexFeatureParsing.string(object, keys: ["stderr", "errorOutput"]),
            startedAt: CodexFeatureParsing.date(object, keys: ["startedAt", "started_at"]),
            completedAt: CodexFeatureParsing.date(object, keys: ["completedAt", "completed_at", "endedAt", "ended_at"]),
            raw: value
        )
    }
}

public struct CodexCommandOutputDelta: Equatable, Sendable {
    public var processID: String
    public var stream: String
    public var text: String
    public var sequence: Int?
    public var isFinal: Bool
    public var raw: JSONValue

    public init(
        processID: String,
        stream: String = "stdout",
        text: String,
        sequence: Int? = nil,
        isFinal: Bool = false,
        raw: JSONValue = .object([:])
    ) {
        self.processID = processID
        self.stream = stream
        self.text = text
        self.sequence = sequence
        self.isFinal = isFinal
        self.raw = raw
    }

    public static func parse(_ value: JSONValue) -> CodexCommandOutputDelta? {
        if let text = value.stringValue {
            return CodexCommandOutputDelta(processID: "", text: text, raw: value)
        }
        guard let object = CodexFeatureParsing.object(value, unwrapping: ["event", "output"]) else {
            return nil
        }
        return CodexCommandOutputDelta(
            processID: CodexFeatureParsing.string(object, keys: ["processId", "processID", "id"]) ?? "",
            stream: CodexFeatureParsing.string(object, keys: ["stream", "fd"]) ?? "stdout",
            text: CodexFeatureParsing.string(object, keys: ["delta", "text", "output", "data"]) ?? "",
            sequence: CodexFeatureParsing.int(object, keys: ["sequence", "seq", "index"]),
            isFinal: CodexFeatureParsing.bool(object, keys: ["isFinal", "final", "closed", "eof"]) ?? false,
            raw: value
        )
    }
}

private enum CodexFeatureParsing {
    static func object(_ value: JSONValue, unwrapping keys: [String]) -> [String: JSONValue]? {
        guard let object = value.objectValue else { return nil }
        for key in keys {
            if let nested = object[key]?.objectValue {
                var merged = object
                merged.removeValue(forKey: key)
                for (nestedKey, nestedValue) in nested {
                    merged[nestedKey] = nestedValue
                }
                return merged
            }
        }
        return object
    }

    static func array(_ value: JSONValue, keys: [String]) -> [JSONValue] {
        if let array = value.arrayValue {
            return array
        }
        guard let object = value.objectValue else { return [] }
        for key in keys {
            if let array = object[key]?.arrayValue {
                return array
            }
            if let nestedObject = object[key]?.objectValue {
                for nestedKey in keys where nestedKey != key {
                    if let array = nestedObject[nestedKey]?.arrayValue {
                        return array
                    }
                }
            }
        }
        return []
    }

    static func string(_ object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value.stringValue {
                return string
            }
            if let number = value.numberValue {
                return format(number)
            }
            if let bool = value.boolValue {
                return String(bool)
            }
        }
        return nil
    }

    static func bool(_ object: [String: JSONValue], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let bool = value.boolValue {
                return bool
            }
            if let string = value.stringValue?.lowercased() {
                if ["true", "yes", "1"].contains(string) {
                    return true
                }
                if ["false", "no", "0"].contains(string) {
                    return false
                }
            }
            if let number = value.numberValue {
                return number != 0
            }
        }
        return nil
    }

    static func int(_ object: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let int = object[key]?.intValue {
                return int
            }
        }
        return nil
    }

    static func double(_ object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let double = object[key]?.numberValue {
                return double
            }
        }
        return nil
    }

    static func date(_ object: [String: JSONValue], keys: [String]) -> Date? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let seconds = value.numberValue {
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = value.stringValue {
                if let seconds = Double(string) {
                    return Date(timeIntervalSince1970: seconds)
                }
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private static func format(_ number: Double) -> String {
        if number.rounded(.towardZero) == number {
            return String(Int(number))
        }
        return String(number)
    }
}
