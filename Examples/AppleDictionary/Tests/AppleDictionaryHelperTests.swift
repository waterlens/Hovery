import Darwin
import Foundation
import XCTest

final class AppleDictionaryHelperTests: XCTestCase {
    func testLookupReturnsAFormattedDefinition() throws {
        let result = try lookup("install-extensions")
        let content = try XCTUnwrap(result["content"] as? String)
        let format = try XCTUnwrap(result["format"] as? String)

        XCTAssertEqual(result["found"] as? Bool, true)
        XCTAssertEqual(result["term"] as? String, "install")
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(["html", "text"].contains(format))
    }

    func testLookupReportsAMissWithoutText() throws {
        let result = try lookup("qxzvkjwpqlmz")

        // The page describes a miss in the user's language, so the helper sends no text for it.
        XCTAssertEqual(result["found"] as? Bool, false)
        XCTAssertEqual(result["term"] as? String, "qxzvkjwpqlmz")
        XCTAssertNil(result["content"])
        XCTAssertNil(result["format"])
    }

    /// Sends one lookup request to a new helper process and returns the result of its response.
    private func lookup(_ text: String) throws -> [String: Any] {
        let executableURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppleDictionaryHelper", isDirectory: false)

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
        }

        let request: [String: Any] = [
            "id": "lookup-test",
            "capability": "org.hovery.capability.system-dictionary",
            "method": "lookup",
            "arguments": ["text": text]
        ]
        var requestData = try JSONSerialization.data(withJSONObject: request)
        requestData.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: requestData)

        var responseData = Data()
        while responseData.firstIndex(of: 0x0A) == nil {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(
                output.fileHandleForReading.fileDescriptor,
                &buffer,
                buffer.count
            )
            guard count > 0 else {
                XCTFail("The helper exited before returning a complete response.")
                return [:]
            }
            responseData.append(contentsOf: buffer.prefix(count))
        }
        let line = try XCTUnwrap(responseData.split(separator: 0x0A).first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
        XCTAssertEqual(object["id"] as? String, "lookup-test")
        return try XCTUnwrap(object["result"] as? [String: Any])
    }
}
