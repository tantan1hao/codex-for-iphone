import XCTest
@testable import CodexMobileKit

final class AppServerFeatureModelsTests: XCTestCase {
    func testParsesJSONValueNumbersAndBooleansFromStrings() throws {
        let raw = #"{"total_tokens":"1200","enabled":"true","items":[{"id":"mode_plan","title":"Plan"}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(object["total_tokens"]?.intValue, 1200)
        XCTAssertEqual(CodexCollaborationMode.parseListResponse(value), [
            CodexCollaborationMode(id: "mode_plan", title: "Plan", raw: ["id": "mode_plan", "title": "Plan"]),
        ])
        XCTAssertEqual(CodexAutomationTaskSummary.parse(["id": "task_1", "enabled": "true"])?.isEnabled, true)
    }

    func testParsesBase64FileContentData() throws {
        let encoded = try XCTUnwrap("hello".data(using: .utf8)?.base64EncodedString())
        let content = try XCTUnwrap(CodexRemoteFileContent.parse([
            "path": "/tmp/hello.txt",
            "encoding": "base64",
            "content": .string(encoded),
            "mimeType": "text/plain",
        ]))

        XCTAssertEqual(content.path, "/tmp/hello.txt")
        XCTAssertEqual(content.data, Data("hello".utf8))
        XCTAssertEqual(content.decodedText, "hello")
        XCTAssertEqual(content.size, 5)
        XCTAssertTrue(content.isBase64Encoded)
    }

    func testTokenUsagePercentRemaining() throws {
        let usage = try XCTUnwrap(CodexTokenUsage.parse([
            "total_tokens": 750,
            "token_limit": 1_000,
        ]))

        XCTAssertEqual(usage.totalTokens, 750)
        XCTAssertEqual(usage.percentRemaining, 25)
    }

    func testFindsNestedTokenUsage() throws {
        let value: JSONValue = [
            "thread": [
                "turns": [
                    [
                        "response": [
                            "token_usage": [
                                "tokens_in_context": 80_000,
                                "context_window": 258_000,
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let usage = try XCTUnwrap(CodexTokenUsage.find(in: value))
        XCTAssertEqual(usage.totalTokens, 80_000)
        XCTAssertEqual(usage.tokenLimit, 258_000)
        XCTAssertEqual(Int((try XCTUnwrap(usage.percentRemaining)).rounded()), 69)
    }

    func testParsesAppServerThreadTokenUsageNotification() throws {
        let value: JSONValue = [
            "threadId": "thr_1",
            "turnId": "turn_1",
            "tokenUsage": [
                "total": [
                    "totalTokens": 80_000,
                    "inputTokens": 70_000,
                    "cachedInputTokens": 10_000,
                    "outputTokens": 9_000,
                    "reasoningOutputTokens": 1_000,
                ],
                "last": [
                    "totalTokens": 12_000,
                    "inputTokens": 10_000,
                    "cachedInputTokens": 2_000,
                    "outputTokens": 1_500,
                    "reasoningOutputTokens": 500,
                ],
                "modelContextWindow": 258_000,
            ],
        ]

        let usage = try XCTUnwrap(CodexTokenUsage.find(in: value))
        XCTAssertEqual(usage.totalTokens, 80_000)
        XCTAssertEqual(usage.inputTokens, 70_000)
        XCTAssertEqual(usage.cachedInputTokens, 10_000)
        XCTAssertEqual(usage.outputTokens, 9_000)
        XCTAssertEqual(usage.reasoningOutputTokens, 1_000)
        XCTAssertEqual(usage.tokenLimit, 258_000)
        XCTAssertEqual(Int((try XCTUnwrap(usage.percentRemaining)).rounded()), 69)
    }

    func testParsesCoreTokenUsageInfoShape() throws {
        let value: JSONValue = [
            "info": [
                "total_token_usage": [
                    "total_tokens": 31_000,
                    "input_tokens": 28_000,
                    "cached_input_tokens": 4_000,
                    "output_tokens": 2_500,
                    "reasoning_output_tokens": 500,
                ],
                "last_token_usage": [
                    "total_tokens": 4_000,
                    "input_tokens": 3_000,
                    "cached_input_tokens": 500,
                    "output_tokens": 750,
                    "reasoning_output_tokens": 250,
                ],
                "model_context_window": 100_000,
            ],
        ]

        let usage = try XCTUnwrap(CodexTokenUsage.find(in: value))
        XCTAssertEqual(usage.totalTokens, 31_000)
        XCTAssertEqual(usage.tokenLimit, 100_000)
        XCTAssertEqual(Int((try XCTUnwrap(usage.percentRemaining)).rounded()), 69)
    }

    func testParsesAutomationTaskAliases() throws {
        let value: JSONValue = [
            "data": [
                "automation_tasks": [
                    [
                        "automation_id": "auto_1",
                        "displayName": "每日总结",
                        "run_status": "scheduled",
                        "schedule_description": "每天 09:00",
                        "instructions": "总结昨天的变更",
                        "next_run": "2026-04-30T01:00:00Z",
                        "is_enabled": "true",
                    ],
                ],
            ],
        ]

        let task = try XCTUnwrap(CodexAutomationTaskSummary.parseListResponse(value).first)
        XCTAssertEqual(task.id, "auto_1")
        XCTAssertEqual(task.title, "每日总结")
        XCTAssertEqual(task.status, "scheduled")
        XCTAssertEqual(task.schedule, "每天 09:00")
        XCTAssertEqual(task.prompt, "总结昨天的变更")
        XCTAssertEqual(task.isEnabled, true)
        XCTAssertNotNil(task.nextRunAt)
    }

    func testParsesAccountRateLimitUsageQuota() throws {
        let value: JSONValue = [
            "rateLimits": [
                "limitId": "codex",
                "limitName": "Codex",
                "planType": "pro",
                "primary": [
                    "usedPercent": 37,
                    "resetsAt": 1_776_000_000,
                    "windowDurationMins": 300,
                ],
            ],
        ]

        let quota = try XCTUnwrap(CodexUsageQuota.parse(value))
        XCTAssertEqual(quota.limitID, "codex")
        XCTAssertEqual(quota.limitName, "Codex")
        XCTAssertEqual(quota.planType, "pro")
        XCTAssertEqual(quota.resolvedUsedFraction, 0.37)
        XCTAssertEqual(quota.resolvedRemainingFraction, 0.63)
        XCTAssertEqual(quota.windowDurationMinutes, 300)
        XCTAssertNotNil(quota.resetsAt)
    }

    func testPrefersCodexRateLimitBucket() throws {
        let value: JSONValue = [
            "rateLimits": [
                "limitId": "default",
                "primary": [
                    "usedPercent": 10,
                ],
            ],
            "rateLimitsByLimitId": [
                "other": [
                    "limitId": "other",
                    "primary": [
                        "usedPercent": 20,
                    ],
                ],
                "codex": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 55,
                    ],
                ],
            ],
        ]

        let quota = try XCTUnwrap(CodexUsageQuota.parse(value))
        XCTAssertEqual(quota.limitID, "codex")
        XCTAssertEqual(quota.resolvedUsedFraction, 0.55)
    }

    func testTokenUsageRejectsObjectsWithoutUsageFields() throws {
        XCTAssertNil(CodexTokenUsage.parse([
            "id": "thread-1",
            "preview": "hello",
        ]))
    }

    func testFileEntryDirectoryAndImageDetection() throws {
        let directory = try XCTUnwrap(CodexRemoteFileEntry.parse([
            "path": "/workspace/Sources",
            "type": "directory",
        ]))
        let image = try XCTUnwrap(CodexRemoteFileEntry.parse([
            "path": "/workspace/cover.PNG",
            "mimeType": "image/png",
        ]))
        let svgByExtension = try XCTUnwrap(CodexRemoteFileEntry.parse("/workspace/icon.svg"))

        XCTAssertTrue(directory.isDirectory)
        XCTAssertFalse(directory.isImage)
        XCTAssertFalse(image.isDirectory)
        XCTAssertTrue(image.isImage)
        XCTAssertTrue(svgByExtension.isImage)
    }
}
