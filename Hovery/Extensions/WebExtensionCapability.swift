import Foundation

@MainActor
protocol WebExtensionNativeInvoking: AnyObject {
    func invoke(capability: String, method: String, arguments: [String: Any]) async throws -> Any
    func cancelPendingRequests()
    func stop()
}

extension WebExtensionNativeInvoking {
    func cancelPendingRequests() {}
    func stop() {}
}

enum WebExtensionCapabilityError: LocalizedError {
    case notDeclared(String)
    case unavailable
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .notDeclared(let identifier):
            "The extension did not declare the \(identifier) capability."
        case .unavailable:
            "This extension does not provide a native helper."
        case .invalidMessage:
            "The extension sent an invalid capability request."
        }
    }
}

@MainActor
final class WebExtensionCapabilityBroker {
    private let descriptor: WebExtensionDescriptor
    private let nativeInvoker: (any WebExtensionNativeInvoking)?

    init(
        descriptor: WebExtensionDescriptor,
        configuration: HoveryConfiguration.WebExtensions,
        nativeInvoker: (any WebExtensionNativeInvoking)? = nil
    ) {
        self.descriptor = descriptor
        if let nativeInvoker {
            self.nativeInvoker = nativeInvoker
        } else if descriptor.nativeHost != nil {
            self.nativeInvoker = WebExtensionNativeHost(
                descriptor: descriptor,
                requestTimeout: configuration.nativeRequestTimeout,
                maximumMessageBytes: configuration.nativeMaximumMessageBytes
            )
        } else {
            self.nativeInvoker = nil
        }
    }

    func invoke(
        capability identifier: String,
        method: String,
        arguments: [String: Any]
    ) async throws -> Any {
        guard descriptor.allowedCapabilities.contains(identifier) else {
            throw WebExtensionCapabilityError.notDeclared(identifier)
        }
        guard let nativeInvoker else {
            throw WebExtensionCapabilityError.unavailable
        }
        return try await nativeInvoker.invoke(
            capability: identifier,
            method: method,
            arguments: arguments
        )
    }

    func cancelPendingRequests() {
        nativeInvoker?.cancelPendingRequests()
    }

    func stop() {
        nativeInvoker?.stop()
    }
}
