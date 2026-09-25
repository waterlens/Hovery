import Foundation
import UniformTypeIdentifiers
import WebKit

final class WebExtensionResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "hovery-extension"

    private let descriptor: WebExtensionDescriptor
    private let networkOrigins: [String]
    private let fileManager: FileManager

    /// `networkOrigins` defaults to the manifest's origins; the runtime adds origins granted by URL settings.
    init(
        descriptor: WebExtensionDescriptor,
        networkOrigins: [String]? = nil,
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.networkOrigins = networkOrigins ?? descriptor.allowedNetworkOrigins
        self.fileManager = fileManager
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            let responseURL = try requestedURL(for: urlSchemeTask.request)
            let requestURL = try validatedURL(for: urlSchemeTask.request)
            var data = try Data(contentsOf: requestURL)
            if requestURL.pathExtension.lowercased() == "html" {
                data = injectContentSecurityPolicy(into: data)
            }

            let mimeType = Self.mimeType(for: requestURL)
            let response = HTTPURLResponse(
                url: responseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Cache-Control": "no-store"
                ]
            ) ?? URLResponse(
                url: responseURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func requestedURL(for request: URLRequest) throws -> URL {
        guard let url = request.url else {
            throw WebExtensionResourceError.invalidRequest
        }
        return url
    }

    private func validatedURL(for request: URLRequest) throws -> URL {
        let url = try requestedURL(for: request)
        guard url.scheme == Self.scheme,
              url.host?.lowercased() == descriptor.identifier else {
            throw WebExtensionResourceError.accessDenied
        }

        let relativePath = String(url.path.drop(while: { $0 == "/" }))
        guard !relativePath.isEmpty else {
            throw WebExtensionResourceError.resourceNotFound
        }

        let root = descriptor.packageURL.resolvingSymlinksInPath().standardizedFileURL
        let resource = root
            .appendingPathComponent(relativePath, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resource.path.hasPrefix(rootPrefix) else {
            throw WebExtensionResourceError.accessDenied
        }
        guard fileManager.fileExists(atPath: resource.path) else {
            throw WebExtensionResourceError.resourceNotFound
        }
        return resource
    }

    private func injectContentSecurityPolicy(into data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let networkSources = networkOrigins.joined(separator: " ")
        let connectSources = networkSources.isEmpty ? "'none'" : "'self' \(networkSources)"
        let policy = [
            "default-src 'none'",
            "base-uri 'self'",
            "script-src 'self' 'unsafe-inline'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "font-src 'self' data:",
            "media-src 'self' data:",
            "connect-src \(connectSources)",
            "object-src 'none'",
            "frame-src 'none'",
            "form-action 'none'"
        ].joined(separator: "; ")
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"

        if let headStart = html.range(of: "<head", options: .caseInsensitive),
           let headEnd = html[headStart.lowerBound...].firstIndex(of: ">") {
            html.insert(contentsOf: meta, at: html.index(after: headEnd))
        } else {
            html = meta + html
        }
        return Data(html.utf8)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

enum WebExtensionResourceError: LocalizedError {
    case invalidRequest
    case accessDenied
    case resourceNotFound

    var errorDescription: String? {
        switch self {
        case .invalidRequest: String(localized: "Invalid extension resource request")
        case .accessDenied: String(localized: "Extension resource access denied")
        case .resourceNotFound: String(localized: "Extension resource not found")
        }
    }
}
