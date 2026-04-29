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
}

