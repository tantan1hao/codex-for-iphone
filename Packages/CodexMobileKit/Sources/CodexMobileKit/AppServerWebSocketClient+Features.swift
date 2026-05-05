import Foundation

public extension AppServerWebSocketClient {
    @discardableResult
    func listCollaborationModes() async throws -> [CodexCollaborationMode] {
        let response = try await sendRequest(method: "collaborationMode/list")
        return CodexCollaborationMode.parseListResponse(response)
    }

    @discardableResult
    func listAutomationTasks() async throws -> [CodexAutomationTaskSummary] {
        let response = try await sendFeatureRequest(methods: Self.automationListMethods)
        return CodexAutomationTaskSummary.parseListResponse(response)
    }

    @discardableResult
    func getAutomationTask(id: String) async throws -> CodexAutomationTaskSummary? {
        let response = try await sendFeatureRequest(
            methods: Self.automationGetMethods,
            params: ["id": .string(id)]
        )
        return CodexAutomationTaskSummary.parseGetResponse(response)
    }

    @discardableResult
    func listLocalAutomationTasks(rootPath: String) async throws -> [CodexAutomationTaskSummary] {
        let entries: [CodexRemoteFileEntry]
        do {
            entries = try await readDirectory(path: rootPath, includeHidden: false)
        } catch {
            guard Self.isMissingFileError(error) else { throw error }
            return try await listLocalAutomationTasksFromShell()
        }

        var tasks: [CodexAutomationTaskSummary] = []
        for entry in entries where entry.isDirectory && !entry.name.hasPrefix(".") {
            let directoryPath = entry.path.isEmpty ? "\(rootPath)/\(entry.name)" : entry.path
            let fallbackID = entry.name.isEmpty ? URL(fileURLWithPath: directoryPath).lastPathComponent : entry.name
            do {
                let file = try await readFile(path: "\(directoryPath)/automation.toml")
                guard let text = file.decodedText,
                      let task = CodexAutomationTaskSummary.parseAutomationTOML(text, fallbackID: fallbackID)
                else { continue }
                tasks.append(task)
            } catch {
                guard Self.isMissingFileError(error) else { throw error }
            }
        }

        if tasks.isEmpty {
            return try await listLocalAutomationTasksFromShell()
        }
        return Self.sortedAutomationTasks(tasks)
    }

    @discardableResult
    func listLocalAutomationTasksFromShell() async throws -> [CodexAutomationTaskSummary] {
        let result = try await startCommand(command: "/bin/sh", args: ["-lc", Self.localAutomationListCommand], timeoutSeconds: 10)
        if let exitCode = result.exitCode, exitCode != 0 {
            let message = result.stderr?.isEmpty == false ? result.stderr! : "Codex app-server command/exec could not read local automations."
            throw AppServerClientError.transport(message)
        }
        return Self.sortedAutomationTasks(CodexAutomationTaskSummary.parseAutomationTOMLDump(result.output ?? ""))
    }

    @discardableResult
    func getUsageQuota() async throws -> CodexUsageQuota {
        let response = try await sendFeatureRequest(methods: Self.usageQuotaMethods)
        guard let quota = CodexUsageQuota.parse(response) else {
            throw AppServerClientError.malformedMessage
        }
        return quota
    }

    @discardableResult
    func readDirectory(path: String, includeHidden: Bool = false) async throws -> [CodexRemoteFileEntry] {
        let response = try await sendRequest(
            method: "fs/readDirectory",
            params: [
                "path": .string(path),
                "includeHidden": .bool(includeHidden),
            ]
        )
        return CodexRemoteFileEntry.parseListResponse(response)
    }

    @discardableResult
    func readFile(path: String) async throws -> CodexRemoteFileContent {
        let response = try await sendRequest(method: "fs/readFile", params: ["path": .string(path)])
        return CodexRemoteFileContent.parse(response) ?? CodexRemoteFileContent(path: path, raw: response)
    }

    @discardableResult
    func getFileMetadata(path: String) async throws -> CodexRemoteFileEntry {
        let response = try await sendRequest(method: "fs/getMetadata", params: ["path": .string(path)])
        return CodexRemoteFileEntry.parse(response) ?? CodexRemoteFileEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            raw: response
        )
    }

    @discardableResult
    func startCommand(_ request: CodexCommandExecRequest) async throws -> CodexCommandExecResult {
        let response = try await sendRequest(method: "command/exec", params: request.jsonValue)
        return CodexCommandExecResult.parse(response) ?? CodexCommandExecResult(processID: "", raw: response)
    }

    @discardableResult
    func startCommand(
        command: String,
        cwd: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        stdin: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        timeoutSeconds: Double? = nil
    ) async throws -> CodexCommandExecResult {
        if args.isEmpty {
            return try await startCommand(
                command: "/bin/sh",
                cwd: cwd,
                args: ["-lc", command],
                env: env,
                stdin: stdin,
                cols: cols,
                rows: rows,
                timeoutSeconds: timeoutSeconds
            )
        }
        return try await startCommand(
            CodexCommandExecRequest(
                command: command,
                cwd: cwd,
                args: args,
                env: env,
                stdin: stdin,
                cols: cols,
                rows: rows,
                timeoutSeconds: timeoutSeconds
            )
        )
    }

    @discardableResult
    func writeCommand(processID: String, text: String, closeStdin: Bool = false) async throws -> JSONValue {
        try await sendRequest(
            method: "command/exec/write",
            params: [
                "processId": .string(processID),
                "text": .string(text),
                "closeStdin": .bool(closeStdin),
            ]
        )
    }

    @discardableResult
    func terminateCommand(processID: String) async throws -> JSONValue {
        try await sendRequest(
            method: "command/exec/terminate",
            params: ["processId": .string(processID)]
        )
    }

    @discardableResult
    func resizeCommand(processID: String, cols: Int, rows: Int) async throws -> JSONValue {
        try await sendRequest(
            method: "command/exec/resize",
            params: [
                "processId": .string(processID),
                "cols": .number(Double(cols)),
                "rows": .number(Double(rows)),
            ]
        )
    }

    @discardableResult
    func startCompact(threadID: String) async throws -> JSONValue {
        try await sendRequest(
            method: "thread/compact/start",
            params: ["threadId": .string(threadID)]
        )
    }

    @discardableResult
    func startTurn(
        threadID: String,
        text: String,
        cwd: String,
        settings: CodexSessionSettings,
        collaborationMode: CodexCollaborationMode?
    ) async throws -> JSONValue {
        var params = AppServerWebSocketClient.turnStartParams(
            threadID: threadID,
            text: text,
            cwd: cwd,
            settings: settings
        ).objectValue ?? [:]
        if let collaborationMode {
            params["collaborationMode"] = collaborationMode.wireValue
        }
        return try await sendRequest(method: "turn/start", params: .object(params))
    }
}

private extension CodexCollaborationMode {
    var wireValue: JSONValue {
        switch raw {
        case .object(let object) where !object.isEmpty:
            raw
        case .string:
            raw
        default:
            .string(id)
        }
    }
}

private extension AppServerWebSocketClient {
    static let automationListMethods = [
        "automations/list",
        "automation/list",
        "automation/tasks/list",
        "automations/tasks/list",
    ]

    static let automationGetMethods = [
        "automations/get",
        "automation/get",
        "automation/tasks/get",
        "automations/tasks/get",
    ]

    static let usageQuotaMethods = [
        "account/rateLimits/read",
        "account/rateLimits/get",
        "account/usage",
        "account/quota",
        "usage/quota",
        "quota/usage",
        "billing/usage",
        "billing/quota",
    ]

    func sendFeatureRequest(methods: [String], params: JSONValue? = nil) async throws -> JSONValue {
        var lastError: Error?
        for method in methods {
            do {
                return try await sendRequest(method: method, params: params)
            } catch {
                guard Self.isUnsupportedFeatureMethodError(error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? AppServerClientError.transport("Codex app-server does not expose this feature.")
    }

    static func isUnsupportedFeatureMethodError(_ error: Error) -> Bool {
        if case let AppServerClientError.requestFailed(rpcError) = error,
           rpcError.code == -32601
        {
            return true
        }
        let message = error.localizedDescription
        return message.localizedCaseInsensitiveContains("method") ||
            message.localizedCaseInsensitiveContains("not found") ||
            message.localizedCaseInsensitiveContains("unknown") ||
            message.localizedCaseInsensitiveContains("unsupported")
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.localizedCaseInsensitiveContains("no such file") ||
            message.localizedCaseInsensitiveContains("not found") ||
            message.localizedCaseInsensitiveContains("does not exist")
    }

    static let localAutomationListCommand = #"for file in "$HOME"/.codex/automations/*/automation.toml; do [ -f "$file" ] || continue; printf "__CODEX_MOBILE_AUTOMATION_BEGIN__ %s\n" "$file"; cat "$file"; printf "\n__CODEX_MOBILE_AUTOMATION_END__\n"; done"#

    static func sortedAutomationTasks(_ tasks: [CodexAutomationTaskSummary]) -> [CodexAutomationTaskSummary] {
        tasks.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?):
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
