import XCTest
@testable import CodexMobileKit

final class ConversationReducerTests: XCTestCase {
    func testAppendsAgentDeltaAndCompletesTurn() {
        var state = ConversationState(threadID: "thr")
        ConversationReducer.reduce(
            &state,
            event: .notification(method: "turn/started", params: ["threadId": "thr", "turnId": "turn"])
        )
        ConversationReducer.reduce(
            &state,
            event: .notification(method: "item/agentMessage/delta", params: ["itemId": "a1", "delta": "Hello"])
        )
        ConversationReducer.reduce(
            &state,
            event: .notification(method: "item/agentMessage/delta", params: ["itemId": "a1", "delta": " world"])
        )
        ConversationReducer.reduce(
            &state,
            event: .notification(method: "turn/completed", params: ["threadId": "thr"])
        )

        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.items.first?.body, "Hello world")
    }

    func testCreatesApprovalFromServerRequest() {
        var state = ConversationState(threadID: "thr")
        ConversationReducer.reduce(
            &state,
            event: .serverRequest(
                id: .int(9),
                method: "item/commandExecution/requestApproval",
                params: [
                    "command": "xcodebuild test",
                    "turnId": "turn_1",
                    "availableDecisions": ["accept", "acceptForSession", "decline"],
                ]
            )
        )

        XCTAssertEqual(state.activeApproval?.id, .int(9))
        XCTAssertEqual(state.activeTurnID, "turn_1")
        XCTAssertEqual(state.activeApproval?.availableDecisions, ["accept", "acceptForSession", "decline"])
        XCTAssertEqual(state.items.first?.kind, .approval)
        XCTAssertEqual(state.items.first?.body, "xcodebuild test")
    }

    func testApprovalResponseUsesStructuredDecision() {
        let request = ApprovalRequest(
            id: .int(10),
            method: "item/commandExecution/requestApproval",
            params: [
                "availableDecisions": [
                    "accept",
                    [
                        "acceptWithExecpolicyAmendment": [
                            "execpolicy_amendment": [],
                        ],
                    ],
                ],
            ]
        )

        let structured = request.decisionOptions[1]
        let response = request.response(decision: structured)

        XCTAssertEqual(response.objectValue?["decision"], structured.value)
        XCTAssertEqual(structured.title, "批准并记住")
    }

    func testPermissionApprovalGrantsRequestedPermissions() {
        let requested: JSONValue = [
            "network": [
                "enabled": true,
            ],
        ]
        let request = ApprovalRequest(
            id: .int(11),
            method: "item/permissions/requestApproval",
            params: [
                "permissions": requested,
                "availableDecisions": ["acceptForSession", "decline"],
            ]
        )

        let accept = request.decisionOptions[0]
        let decline = request.decisionOptions[1]

        XCTAssertEqual(request.response(decision: accept).objectValue?["scope"], "session")
        XCTAssertEqual(request.response(decision: accept).objectValue?["permissions"], requested)
        XCTAssertEqual(request.response(decision: decline).objectValue?["scope"], "turn")
        XCTAssertEqual(request.response(decision: decline).objectValue?["permissions"], .object([:]))
    }

    func testTracksActiveTurnIDFromNotifications() {
        var state = ConversationState(threadID: "thr")
        ConversationReducer.reduce(
            &state,
            event: .notification(method: "turn/started", params: ["threadId": "thr", "turnId": "turn_1"])
        )

        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.activeTurnID, "turn_1")

        ConversationReducer.reduce(
            &state,
            event: .notification(method: "turn/completed", params: ["threadId": "thr", "turnId": "turn_1"])
        )

        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.activeTurnID)
    }

    func testBuildsConversationFromResumeResponseTurns() {
        let response: JSONValue = [
            "thread": [
                "id": "thr",
                "turns": [
                    [
                        "id": "turn_1",
                        "status": "completed",
                        "items": [
                            [
                                "type": "userMessage",
                                "id": "u1",
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "帮我跑测试",
                                    ],
                                ],
                            ],
                            [
                                "type": "agentMessage",
                                "id": "a1",
                                "text": "我来检查。",
                            ],
                            [
                                "type": "commandExecution",
                                "id": "cmd1",
                                "command": "swift test",
                                "aggregatedOutput": "Build complete",
                                "status": "completed",
                            ],
                        ],
                    ],
                    [
                        "id": "turn_2",
                        "status": "inProgress",
                        "items": [],
                    ],
                ],
            ],
        ]

        let state = ConversationReducer.state(fromThreadResponse: response)

        XCTAssertEqual(state.threadID, "thr")
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.items.map(\.kind), [.user, .assistant, .command])
        XCTAssertEqual(state.items[0].body, "帮我跑测试")
        XCTAssertEqual(state.items[1].body, "我来检查。")
        XCTAssertEqual(state.items[2].title, "swift test")
        XCTAssertEqual(state.items[2].body, "Build complete")
    }

    func testBuildsConversationFromTurnsListResponseInChronologicalOrder() {
        let response: JSONValue = [
            "data": [
                [
                    "id": "turn_new",
                    "status": "completed",
                    "items": [
                        [
                            "type": "agentMessage",
                            "id": "a_new",
                            "text": "新的回复",
                        ],
                    ],
                ],
                [
                    "id": "turn_old",
                    "status": "completed",
                    "items": [
                        [
                            "type": "userMessage",
                            "id": "u_old",
                            "content": [
                                [
                                    "type": "text",
                                    "text": "旧问题",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "nextCursor": "older",
        ]

        let state = ConversationReducer.state(fromTurnsListResponse: response, threadID: "thr")

        XCTAssertEqual(state.threadID, "thr")
        XCTAssertEqual(state.items.map(\.id), ["u_old", "a_new"])
        XCTAssertEqual(ConversationReducer.nextCursor(fromTurnsListResponse: response), "older")
    }

    func testMergingReplacesDuplicateTailWithServerItems() {
        var existing = ConversationState(threadID: "thr")
        existing.items = [
            ConversationItem(id: "optimistic-user", kind: .user, title: "You", body: "你好", status: "sending"),
            ConversationItem(id: "stream-assistant", kind: .assistant, title: "Codex", body: "你好，我是 Codex。"),
        ]
        var incoming = ConversationState(threadID: "thr")
        incoming.items = [
            ConversationItem(id: "server-user", kind: .user, title: "You", body: "你好"),
            ConversationItem(id: "server-assistant", kind: .assistant, title: "Codex", body: "你好，我是 Codex。"),
        ]

        let merged = ConversationReducer.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.items.map(\.id), ["server-user", "server-assistant"])
        XCTAssertEqual(merged.items.map(\.body), ["你好", "你好，我是 Codex。"])
    }

    func testPrependingOlderSkipsOverlappingBoundaryItems() {
        var existing = ConversationState(threadID: "thr")
        existing.items = [
            ConversationItem(id: "u2", kind: .user, title: "You", body: "继续"),
            ConversationItem(id: "a2", kind: .assistant, title: "Codex", body: "可以。"),
        ]
        var older = ConversationState(threadID: "thr")
        older.items = [
            ConversationItem(id: "u1", kind: .user, title: "You", body: "你好"),
            ConversationItem(id: "a1", kind: .assistant, title: "Codex", body: "你好。"),
            ConversationItem(id: "server-u2", kind: .user, title: "You", body: "继续"),
        ]

        let merged = ConversationReducer.prependingOlder(existing: existing, older: older)

        XCTAssertEqual(merged.items.map(\.body), ["你好", "你好。", "继续", "可以。"])
        XCTAssertEqual(merged.items.filter { $0.body == "继续" }.count, 1)
    }
}
