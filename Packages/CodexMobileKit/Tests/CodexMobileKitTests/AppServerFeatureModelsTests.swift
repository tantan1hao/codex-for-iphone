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
