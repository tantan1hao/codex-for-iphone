import Foundation

public extension AppServerWebSocketClient {
    @discardableResult
    func listCollaborationModes() async throws -> [CodexCollaborationMode] {
        let response = try await sendRequest(method: "collaborationMode/list")
        return CodexCollaborationMode.parseListResponse(response)
    }

    @discardableResult
    func listAutomationTasks() async throws -> [CodexAutomationTaskSummary] {
        let response = try await sendRequest(method: "tasks/list")
        return CodexAutomationTaskSummary.parseListResponse(response)
    }

    @discardableResult
    func getAutomationTask(id: String) async throws -> CodexAutomationTaskSummary? {
        let response = try await sendRequest(method: "tasks/get", params: ["id": .string(id)])
        return CodexAutomationTaskSummary.parseGetResponse(response)
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
        try await startCommand(
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
