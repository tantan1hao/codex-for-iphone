import XCTest
@testable import CodexMobileKit

final class SessionSettingsTests: XCTestCase {
    func testParsesModelListResponse() {
        let response: JSONValue = [
            "data": [
                [
                    "id": "gpt-5.5",
                    "model": "gpt-5.5",
                    "displayName": "GPT-5.5",
                    "defaultReasoningEffort": "xhigh",
                    "isDefault": true,
                    "supportedReasoningEfforts": [
                        ["reasoningEffort": "medium"],
                        ["reasoningEffort": "high"],
                        ["reasoningEffort": "xhigh"],
                    ],
                    "additionalSpeedTiers": ["fast"],
                ],
            ],
        ]

        let models = CodexModelOption.parseListResponse(response)

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, "gpt-5.5")
        XCTAssertEqual(models.first?.displayName, "GPT-5.5")
        XCTAssertEqual(models.first?.defaultReasoningEffort, "xhigh")
        XCTAssertEqual(models.first?.supportedReasoningEfforts, ["medium", "high", "xhigh"])
        XCTAssertEqual(models.first?.additionalSpeedTiers, ["fast"])
        XCTAssertEqual(models.first?.isDefault, true)
    }

    func testPermissionPresetMapsToCodexConfigAndTurnSandbox() {
        XCTAssertEqual(CodexPermissionPreset.readOnly.approvalPolicy, .string("on-request"))
        XCTAssertEqual(CodexPermissionPreset.readOnly.sandboxMode, .string("read-only"))
        XCTAssertEqual(CodexPermissionPreset.workspaceWrite.sandboxMode, .string("workspace-write"))
        XCTAssertEqual(CodexPermissionPreset.fullAccess.approvalPolicy, .string("never"))
        XCTAssertEqual(CodexPermissionPreset.fullAccess.sandboxMode, .string("danger-full-access"))

        let sandbox = CodexPermissionPreset.workspaceWrite.turnSandboxPolicy(cwd: "/Users/mac/CodexMobile")
        XCTAssertEqual(sandbox.objectValue?["type"], .string("workspaceWrite"))
        XCTAssertEqual(sandbox.objectValue?["writableRoots"], .array([.string("/Users/mac/CodexMobile")]))
        XCTAssertEqual(sandbox.objectValue?["networkAccess"], .bool(false))
    }

    func testInfersPermissionPresetFromConfig() {
        XCTAssertEqual(
            CodexPermissionPreset.fromConfig(approvalPolicy: .string("on-request"), sandboxMode: .string("read-only")),
            .readOnly
        )
        XCTAssertEqual(
            CodexPermissionPreset.fromConfig(approvalPolicy: .string("on-request"), sandboxMode: .string("workspace-write")),
            .workspaceWrite
        )
        XCTAssertEqual(
            CodexPermissionPreset.fromConfig(approvalPolicy: .string("never"), sandboxMode: .string("workspace-write")),
            .fullAccess
        )
        XCTAssertEqual(
            CodexPermissionPreset.fromConfig(approvalPolicy: .string("on-request"), sandboxMode: .string("danger-full-access")),
            .fullAccess
        )
    }
}
