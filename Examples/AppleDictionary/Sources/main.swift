import CoreFoundation
import CoreServices
import Darwin
import Foundation

private enum ProtocolConstants {
    static let capability = "org.hovery.capability.system-dictionary"
    static let lookupMethod = "lookup"
}

private enum HelperError: LocalizedError {
    case invalidRequest
    case unsupportedCapability(String)
    case unsupportedMethod(String)
    case missingText

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Invalid native extension request."
        case .unsupportedCapability(let capability):
            "Unsupported capability: \(capability)"
        case .unsupportedMethod(let method):
            "Unsupported dictionary method: \(method)"
        case .missingText:
            "Dictionary lookup requires text."
        }
    }
}

private struct DictionaryResult {
    let term: String
    let format: String
    let content: String
    let dictionary: String?

    var payload: [String: Any] {
        [
            "term": term,
            "format": format,
            "content": content,
            "dictionary": dictionary ?? NSNull()
        ]
    }
}

private final class DictionaryLookup {
    func invoke(capability: String, method: String, arguments: [String: Any]) throws -> [String: Any] {
        guard capability == ProtocolConstants.capability else {
            throw HelperError.unsupportedCapability(capability)
        }
        guard method == ProtocolConstants.lookupMethod else {
            throw HelperError.unsupportedMethod(method)
        }
        guard let suppliedText = arguments["text"] as? String else {
            throw HelperError.missingText
        }
        let text = suppliedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HelperError.missingText }

        let detectedTerm = detectedTerm(in: text) ?? text
        var richCandidates = [text]
        if detectedTerm != text {
            richCandidates.append(detectedTerm)
        }
        for candidate in richCandidates {
            if let richResult = RichDictionaryServices.shared?.lookup(candidate) {
                return richResult.payload
            }
        }
        if let definition = plainTextDefinition(for: detectedTerm) {
            return DictionaryResult(
                term: detectedTerm,
                format: "text",
                content: definition,
                dictionary: nil
            ).payload
        }
        return DictionaryResult(
            term: text,
            format: "text",
            content: "No definition found.",
            dictionary: nil
        ).payload
    }

    private func detectedTerm(in text: String) -> String? {
        let value = text as CFString
        let range = DCSGetTermRangeInString(nil, value, 0)
        guard range.location != kCFNotFound,
              range.location >= 0,
              range.length > 0,
              range.location + range.length <= CFStringGetLength(value) else { return nil }
        return (text as NSString).substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private func plainTextDefinition(for text: String) -> String? {
        let value = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(value))
        return DCSCopyTextDefinition(nil, value, range)?.takeRetainedValue() as String?
    }
}

/// Apple does not expose its rich Dictionary panel document through the public
/// DictionaryServices header. This extension resolves that implementation at
/// runtime and keeps the public plain-text API as its fallback.
private final class RichDictionaryServices {
    typealias CopyActiveDictionaries = @convention(c) (CFDictionary?) -> Unmanaged<CFTypeRef>?
    typealias CopyRecords = @convention(c) (
        UnsafeRawPointer?,
        CFString,
        UInt,
        Int
    ) -> Unmanaged<CFTypeRef>?
    typealias CopyRecordData = @convention(c) (UnsafeRawPointer?, Int) -> Unmanaged<CFTypeRef>?
    typealias GetDictionaryName = @convention(c) (UnsafeRawPointer?) -> Unmanaged<CFString>?

    nonisolated(unsafe) static let shared = RichDictionaryServices()

    private enum RecordStyle {
        static let panel = 2
        static let maximumCount = 8
    }

    private let handle: UnsafeMutableRawPointer
    private let copyActiveDictionaries: CopyActiveDictionaries
    private let copyRecords: CopyRecords
    private let copyRecordData: CopyRecordData
    private let getDictionaryName: GetDictionaryName

    private init?() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let copyDictionariesSymbol = dlsym(handle, "DCSCopyActiveDictionaries"),
              let copyRecordsSymbol = dlsym(handle, "DCSCopyRecordsForSearchString"),
              let copyRecordDataSymbol = dlsym(handle, "DCSRecordCopyData"),
              let getDictionaryNameSymbol = dlsym(handle, "DCSDictionaryGetName") else {
            return nil
        }
        self.handle = handle
        copyActiveDictionaries = unsafeBitCast(
            copyDictionariesSymbol,
            to: CopyActiveDictionaries.self
        )
        copyRecords = unsafeBitCast(copyRecordsSymbol, to: CopyRecords.self)
        copyRecordData = unsafeBitCast(copyRecordDataSymbol, to: CopyRecordData.self)
        getDictionaryName = unsafeBitCast(getDictionaryNameSymbol, to: GetDictionaryName.self)
    }

    func lookup(_ text: String) -> DictionaryResult? {
        guard let collection = copyActiveDictionaries(nil)?.takeRetainedValue() else { return nil }
        for dictionary in pointers(in: collection) {
            guard let recordCollection = copyRecords(
                dictionary,
                text as CFString,
                0,
                RecordStyle.maximumCount
            )?.takeRetainedValue() else { continue }

            for record in pointers(in: recordCollection) {
                guard let data = copyRecordData(record, RecordStyle.panel)?.takeRetainedValue(),
                      CFGetTypeID(data) == CFStringGetTypeID() else { continue }
                let html = unsafeDowncast(data, to: CFString.self) as String
                guard !html.isEmpty else { continue }
                let dictionaryName = getDictionaryName(dictionary)?.takeUnretainedValue() as String?
                return DictionaryResult(
                    term: text,
                    format: "html",
                    content: html,
                    dictionary: dictionaryName
                )
            }
        }
        return nil
    }

    private func pointers(in collection: CFTypeRef) -> [UnsafeRawPointer] {
        if CFGetTypeID(collection) == CFArrayGetTypeID() {
            let array = unsafeDowncast(collection, to: CFArray.self)
            return (0..<CFArrayGetCount(array)).compactMap { CFArrayGetValueAtIndex(array, $0) }
        }
        if CFGetTypeID(collection) == CFSetGetTypeID() {
            let set = unsafeDowncast(collection, to: CFSet.self)
            let count = CFSetGetCount(set)
            var values = Array<UnsafeRawPointer?>(repeating: nil, count: count)
            CFSetGetValues(set, &values)
            return values.compactMap { $0 }
        }
        return []
    }
}

private let lookup = DictionaryLookup()
while let line = readLine() {
    let response: [String: Any] = autoreleasepool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any],
              let requestID = request["id"] as? String,
              let capability = request["capability"] as? String,
              let method = request["method"] as? String,
              let arguments = request["arguments"] as? [String: Any] else {
            return [
                "id": "",
                "error": ["message": HelperError.invalidRequest.localizedDescription]
            ]
        }

        do {
            return [
                "id": requestID,
                "result": try lookup.invoke(
                    capability: capability,
                    method: method,
                    arguments: arguments
                )
            ]
        } catch {
            return [
                "id": requestID,
                "error": ["message": error.localizedDescription]
            ]
        }
    }

    if let data = try? JSONSerialization.data(withJSONObject: response),
       let output = String(data: data, encoding: .utf8) {
        print(output)
        fflush(stdout)
    }
}
