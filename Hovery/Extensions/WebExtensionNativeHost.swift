@preconcurrency import Foundation
import OSLog
import Security

enum WebExtensionNativeHostError: LocalizedError {
    case missingExecutable
    case executableNotRunnable(String)
    case invalidSignature(String)
    case launchFailed(String)
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case invalidResponse
    case helperError(String)
    case timedOut
    case cancelled
    case terminated

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "The extension does not declare a native executable."
        case .executableNotRunnable(let path):
            "The native extension executable cannot be run: \(path)"
        case .invalidSignature(let message):
            "The native extension signature is invalid: \(message)"
        case .launchFailed(let message):
            "The native extension could not start: \(message)"
        case .invalidRequest:
            "The native extension request is not valid JSON."
        case .requestTooLarge:
            "The native extension request exceeds the configured size limit."
        case .responseTooLarge:
            "The native extension response exceeds the configured size limit."
        case .invalidResponse:
            "The native extension returned an invalid response."
        case .helperError(let message):
            message
        case .timedOut:
            "The native extension request timed out."
        case .cancelled:
            "The native extension request was cancelled."
        case .terminated:
            "The native extension process exited."
        }
    }
}

@MainActor
final class WebExtensionNativeHost: WebExtensionNativeInvoking {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Any, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let descriptor: WebExtensionDescriptor
    private let requestTimeout: Duration
    private let maximumMessageBytes: Int
    private let logger: Logger
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var responseBuffer = Data()
    private var errorBuffer = Data()
    private var pendingRequests: [String: PendingRequest] = [:]

    init(
        descriptor: WebExtensionDescriptor,
        requestTimeout: Double,
        maximumMessageBytes: Int
    ) {
        self.descriptor = descriptor
        self.requestTimeout = .milliseconds(Int64(requestTimeout * 1_000))
        self.maximumMessageBytes = maximumMessageBytes
        logger = Logger(
            subsystem: "app.hovery.Hovery",
            category: "NativeExtension.\(descriptor.identifier)"
        )
    }

    func invoke(capability: String, method: String, arguments: [String: Any]) async throws -> Any {
        guard !capability.isEmpty, !method.isEmpty,
              JSONSerialization.isValidJSONObject(arguments) else {
            throw WebExtensionNativeHostError.invalidRequest
        }
        try startIfNeeded()

        let requestID = UUID().uuidString
        let request: [String: Any] = [
            "id": requestID,
            "capability": capability,
            "method": method,
            "arguments": arguments
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        guard data.count <= maximumMessageBytes else {
            throw WebExtensionNativeHostError.requestTooLarge
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: requestTimeout)
                failRequest(requestID, with: WebExtensionNativeHostError.timedOut)
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try standardInput?.write(contentsOf: data)
            } catch {
                failRequest(requestID, with: WebExtensionNativeHostError.terminated)
            }
        }
    }

    func cancelPendingRequests() {
        failAll(with: WebExtensionNativeHostError.cancelled)
    }

    func stop() {
        failAll(with: WebExtensionNativeHostError.terminated)
        responseBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        guard let native = descriptor.nativeHost else {
            throw WebExtensionNativeHostError.missingExecutable
        }
        let executableURL = descriptor.packageURL
            .appendingPathComponent(native.executablePath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WebExtensionNativeHostError.executableNotRunnable(executableURL.path)
        }
        try WebExtensionNativeSignatureVerifier.verify(executableURL)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = descriptor.packageURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.processDidTerminate()
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.receiveOutput(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.receiveErrorOutput(data)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw WebExtensionNativeHostError.launchFailed(error.localizedDescription)
        }
        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
        logger.notice("Started native extension helper")
    }

    private func receiveOutput(_ data: Data) {
        guard !data.isEmpty else {
            processDidTerminate()
            return
        }
        responseBuffer.append(data)
        guard responseBuffer.count <= maximumMessageBytes else {
            failAll(with: WebExtensionNativeHostError.responseTooLarge)
            stop()
            return
        }
        while let newline = responseBuffer.firstIndex(of: 0x0A) {
            let line = responseBuffer[..<newline]
            responseBuffer.removeSubrange(...newline)
            receiveResponse(Data(line))
        }
    }

    private func receiveResponse(_ data: Data) {
        guard data.count <= maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let requestID = response["id"] as? String,
              let pending = pendingRequests.removeValue(forKey: requestID) else {
            logger.error("Native extension returned an invalid or unknown response")
            return
        }
        pending.timeoutTask.cancel()
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            pending.continuation.resume(throwing: WebExtensionNativeHostError.helperError(message))
        } else if let result = response["result"] {
            pending.continuation.resume(returning: result)
        } else {
            pending.continuation.resume(throwing: WebExtensionNativeHostError.invalidResponse)
        }
    }

    private func receiveErrorOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        errorBuffer.append(data)
        if errorBuffer.count > maximumMessageBytes {
            errorBuffer.removeFirst(errorBuffer.count - maximumMessageBytes)
        }
        while let newline = errorBuffer.firstIndex(of: 0x0A) {
            let line = errorBuffer[..<newline]
            errorBuffer.removeSubrange(...newline)
            if let message = String(data: line, encoding: .utf8), !message.isEmpty {
                logger.error("Helper: \(message, privacy: .public)")
            }
        }
    }

    private func processDidTerminate() {
        guard process != nil else { return }
        logger.error("Native extension helper exited")
        failAll(with: WebExtensionNativeHostError.terminated)
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
    }

    private func failRequest(_ requestID: String, with error: any Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAll(with error: any Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

private enum WebExtensionNativeSignatureVerifier {
    static func verify(_ executableURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            if isRunningTests { return }
            throw WebExtensionNativeHostError.invalidSignature(statusMessage(createStatus))
        }
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            if isRunningTests { return }
            throw WebExtensionNativeHostError.invalidSignature(statusMessage(validityStatus))
        }

        let helperTeam = teamIdentifier(for: staticCode)
        let applicationTeam = currentApplicationTeamIdentifier()
        if let applicationTeam, helperTeam != applicationTeam {
            throw WebExtensionNativeHostError.invalidSignature(
                "The helper must be signed by Team \(applicationTeam)."
            )
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func currentApplicationTeamIdentifier() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        return teamIdentifier(for: code)
    }

    private static func teamIdentifier(for code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func statusMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
