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
                params: ["command": "xcodebuild test"]
            )
        )

        XCTAssertEqual(state.activeApproval?.id, .int(9))
        XCTAssertEqual(state.items.first?.kind, .approval)
        XCTAssertEqual(state.items.first?.body, "xcodebuild test")
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
}
