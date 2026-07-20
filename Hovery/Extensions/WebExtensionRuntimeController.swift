import AppKit
import OSLog
import WebKit

@MainActor
final class WebExtensionRuntimeController: NSViewController, WKNavigationDelegate {
    private enum Runtime {
        static let namespace = "__hoveryESMRuntime"
        static let contentSizeHandler = "hoveryInternalContentSize"
        static let capabilityHandler = "hoveryCapability"
        static let overlayHandler = "hoverySelectionOverlay"
        static let rootSelector = "[data-hovery-root]"
    }

    let descriptor: WebExtensionDescriptor
    var contentHeightDidChange: ((CGFloat) -> Void)?
    var failureDidOccur: ((String) -> Void)?
    var selectionOverlayDidChange: ((_ requestID: String, _ items: [WebExtensionOverlayItem]?) -> Void)?

    private let resourceHandler: WebExtensionResourceHandler
    private let contentSizeHandler = WebExtensionContentSizeHandler()
    private let capabilityBroker: WebExtensionCapabilityBroker
    private let capabilityHandler: WebExtensionCapabilityMessageHandler
    private let overlayHandler = WebExtensionOverlayMessageHandler()
    private let logger: Logger
    private var webView: WKWebView!
    private var hasStartedLoading = false
    private var isMounted = false
    private var pendingRequest: [String: Any]?

    init(
        descriptor: WebExtensionDescriptor,
        nativeConfiguration: WebExtensionConfiguration = .init(),
        nativeInvoker: (any WebExtensionNativeInvoking)? = nil
    ) {
        self.descriptor = descriptor
        resourceHandler = WebExtensionResourceHandler(descriptor: descriptor)
        let capabilityBroker = WebExtensionCapabilityBroker(
            descriptor: descriptor,
            configuration: nativeConfiguration,
            nativeInvoker: nativeInvoker
        )
        self.capabilityBroker = capabilityBroker
        capabilityHandler = WebExtensionCapabilityMessageHandler(
            broker: capabilityBroker
        )
        logger = Logger(
            subsystem: "app.hovery.Hovery",
            category: "WebExtension.\(descriptor.identifier)"
        )
        super.init(nibName: nil, bundle: nil)
        contentSizeHandler.owner = self
        overlayHandler.owner = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let userContentController = WKUserContentController()
        userContentController.add(contentSizeHandler, name: Runtime.contentSizeHandler)
        userContentController.addScriptMessageHandler(
            capabilityHandler,
            contentWorld: .page,
            name: Runtime.capabilityHandler
        )
        userContentController.add(
            overlayHandler,
            contentWorld: .page,
            name: Runtime.overlayHandler
        )
        userContentController.addUserScript(WKUserScript(
            source: Self.contentSizeObserverScript(handlerName: Runtime.contentSizeHandler),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: WebExtensionResourceHandler.scheme)

        webView = InteractiveWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .clear
        view = webView
    }

    func ensureLoaded() {
        loadViewIfNeeded()
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        webView.load(URLRequest(url: extensionURL(path: descriptor.documentPath)))
    }

    func present(request: [String: Any]) {
        pendingRequest = request
        ensureLoaded()
        guard isMounted else { return }
        pendingRequest = nil
        invokePresent(request)
    }

    func cancel() {
        pendingRequest = nil
        capabilityBroker.cancelPendingRequests()
        guard isMounted else { return }
        Task { [self] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    const runtime = globalThis[namespace];
                    if (runtime) {
                        runtime.generation += 1;
                        runtime.controller?.abort();
                        runtime.controller = null;
                    }
                    """,
                    arguments: ["namespace": Runtime.namespace],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                logger.debug("Could not cancel extension request: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func unmount() {
        pendingRequest = nil
        capabilityBroker.stop()
        guard isMounted else { return }
        isMounted = false
        Task { [self] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    const runtime = globalThis[namespace];
                    if (runtime) {
                        runtime.generation += 1;
                        runtime.controller?.abort();
                        if (typeof runtime.module.unmount === "function") {
                            await runtime.module.unmount({
                                root: runtime.root,
                                capabilities: runtime.capabilities
                            });
                        }
                        delete globalThis[namespace];
                    }
                    """,
                    arguments: ["namespace": Runtime.namespace],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                logger.debug("Could not unmount extension: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            await self?.mountModule()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        reportFailure(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == WebExtensionResourceHandler.scheme,
           url.host?.lowercased() == descriptor.identifier {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           ["https", "http"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    fileprivate func receiveContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        contentHeightDidChange?(height)
    }

    private func mountModule() async {
        do {
            _ = try await webView.callAsyncJavaScript(
                """
                const extensionModule = await import(moduleURL);
                if (typeof extensionModule.present !== "function") {
                    throw new TypeError("The ESM entry must export present(request)");
                }
                const root = document.querySelector(rootSelector)
                    ?? document.getElementById("hovery-root")
                    ?? document.body;
                const declaredCapabilities = new Set(extensionInfo.capabilities);
                const createCapabilities = signal => Object.freeze({
                    async invoke(capability, method, arguments = {}) {
                        if (!declaredCapabilities.has(capability)) {
                            throw new Error(`Capability is not declared: ${capability}`);
                        }
                        if (typeof method !== "string" || method.length === 0) {
                            throw new TypeError("A capability method is required");
                        }
                        signal?.throwIfAborted();
                        try {
                            const result = await window.webkit.messageHandlers[capabilityHandler].postMessage({
                                capability,
                                method,
                                arguments
                            });
                            signal?.throwIfAborted();
                            return result;
                        } catch (error) {
                            signal?.throwIfAborted();
                            throw error;
                        }
                    }
                });
                const runtime = {
                    module: extensionModule,
                    root,
                    capabilities: createCapabilities(),
                    createCapabilities,
                    controller: null,
                    generation: 0
                };
                globalThis[namespace] = runtime;
                if (typeof extensionModule.mount === "function") {
                    await extensionModule.mount({
                        root,
                        extension: Object.freeze(extensionInfo),
                        capabilities: runtime.capabilities
                    });
                }
                """,
                arguments: [
                    "moduleURL": extensionURL(path: descriptor.modulePath).absoluteString,
                    "namespace": Runtime.namespace,
                    "rootSelector": Runtime.rootSelector,
                    "capabilityHandler": Runtime.capabilityHandler,
                    "extensionInfo": [
                        "id": descriptor.identifier,
                        "name": descriptor.name,
                        "capabilities": descriptor.allowedCapabilities,
                        "selectionOverlay": descriptor.allowsSelectionOverlay
                    ]
                ],
                in: nil,
                contentWorld: .page
            )
            isMounted = true
            logger.notice("Mounted ESM extension")
            if let pendingRequest {
                self.pendingRequest = nil
                invokePresent(pendingRequest)
            }
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func invokePresent(_ request: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    const runtime = globalThis[namespace];
                    if (!runtime) {
                        throw new Error("Extension runtime is not mounted");
                    }
                    runtime.generation += 1;
                    const generation = runtime.generation;
                    runtime.controller?.abort();
                    const controller = new AbortController();
                    runtime.controller = controller;
                    const colorCanvas = document.createElement("canvas");
                    colorCanvas.width = 1;
                    colorCanvas.height = 1;
                    const colorContext = colorCanvas.getContext("2d", { willReadFrequently: true });
                    const resolveColor = value => {
                        if (value === undefined || value === null) return null;
                        if (typeof value !== "string" || !CSS.supports("color", value)) {
                            throw new TypeError(`Invalid CSS color: ${value}`);
                        }
                        colorContext.clearRect(0, 0, 1, 1);
                        colorContext.fillStyle = value;
                        colorContext.fillRect(0, 0, 1, 1);
                        const [red, green, blue, alpha] = colorContext.getImageData(0, 0, 1, 1).data;
                        return {
                            red: red / 255,
                            green: green / 255,
                            blue: blue / 255,
                            alpha: alpha / 255
                        };
                    };
                    const normalizeStyle = value => {
                        const style = value ?? {};
                        if (typeof style !== "object" || Array.isArray(style)) {
                            throw new TypeError("The overlay style must be an object");
                        }
                        const shadow = style.shadow ?? {};
                        return {
                            fillColor: resolveColor(style.fill),
                            strokeColor: resolveColor(style.stroke),
                            lineWidth: style.lineWidth ?? null,
                            lineDash: style.lineDash ?? null,
                            lineCap: style.lineCap ?? null,
                            material: style.material ?? null,
                            materialOpacity: style.materialOpacity ?? null,
                            shadowColor: resolveColor(shadow.color),
                            shadowRadius: shadow.radius ?? null,
                            shadowOffsetX: shadow.x ?? null,
                            shadowOffsetY: shadow.y ?? null
                        };
                    };
                    const sendOverlay = items => {
                        if (!extensionInfo.selectionOverlay) {
                            throw new Error("Selection overlay permission is not declared");
                        }
                        controller.signal.throwIfAborted();
                        window.webkit.messageHandlers[overlayHandler].postMessage({
                            requestID: request.id,
                            items
                        });
                    };
                    const overlayItems = (value, options = {}) => {
                        const values = Array.isArray(value) ? value : [value];
                        return values.map(item => {
                            const selection = item?.selection ?? item;
                            const style = item?.selection ? item.style : options;
                            if (!selection || typeof selection.id !== "string") {
                                throw new TypeError("overlay.show expects a selection or an array of selections");
                            }
                            return {
                                selectionID: selection.id,
                                style: normalizeStyle(style)
                            };
                        });
                    };
                    const overlay = Object.freeze({
                        showInput(options = {}) {
                            sendOverlay(overlayItems(request.input, options));
                        },
                        show(selection, options = {}) {
                            sendOverlay(overlayItems(selection, options));
                        },
                        clear() {
                            sendOverlay(null);
                        }
                    });
                    const value = Object.freeze({
                        ...request,
                        root: runtime.root,
                        signal: controller.signal,
                        capabilities: runtime.createCapabilities(controller.signal),
                        overlay
                    });
                    try {
                        await runtime.module.present(value);
                    } catch (error) {
                        if (error?.name !== "AbortError") {
                            throw error;
                        }
                    } finally {
                        if (runtime.generation === generation) {
                            runtime.controller = null;
                        }
                    }
                    """,
                    arguments: [
                        "namespace": Runtime.namespace,
                        "request": request,
                        "overlayHandler": Runtime.overlayHandler,
                        "extensionInfo": [
                            "selectionOverlay": descriptor.allowsSelectionOverlay
                        ]
                    ],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                reportFailure(error.localizedDescription)
            }
        }
    }

    private func reportFailure(_ message: String) {
        logger.error("Web extension failed: \(message, privacy: .public)")
        failureDidOccur?(message)
    }

    fileprivate func receiveSelectionOverlayMessage(_ body: [String: Any]) {
        guard descriptor.allowsSelectionOverlay,
              let requestID = body["requestID"] as? String else { return }
        if body["items"] is NSNull {
            selectionOverlayDidChange?(requestID, nil)
            return
        }
        guard let itemPayloads = body["items"] as? [[String: Any]] else { return }
        let items = itemPayloads.compactMap { payload -> WebExtensionOverlayItem? in
            guard let selectionID = payload["selectionID"] as? String,
                  let stylePayload = payload["style"] as? [String: Any],
                  let style = Self.overlayStyle(from: stylePayload) else { return nil }
            return WebExtensionOverlayItem(selectionID: selectionID, style: style)
        }
        guard items.count == itemPayloads.count else { return }
        selectionOverlayDidChange?(requestID, items)
    }

    private static func overlayStyle(from payload: [String: Any]) -> WebExtensionOverlayStyle? {
        guard let fillColor = optionalColor(payload["fillColor"]),
              let strokeColor = optionalColor(payload["strokeColor"]),
              let lineWidth = optionalFiniteDouble(payload["lineWidth"]),
              let lineDash = optionalFiniteDoubleArray(payload["lineDash"]),
              let materialOpacity = optionalFiniteDouble(payload["materialOpacity"]),
              let shadowColor = optionalColor(payload["shadowColor"]),
              let shadowRadius = optionalFiniteDouble(payload["shadowRadius"]),
              let shadowOffsetX = optionalFiniteDouble(payload["shadowOffsetX"]),
              let shadowOffsetY = optionalFiniteDouble(payload["shadowOffsetY"]) else { return nil }
        return WebExtensionOverlayStyle(
            fillColor: fillColor,
            strokeColor: strokeColor,
            lineWidth: lineWidth,
            lineDash: lineDash,
            lineCap: payload["lineCap"] as? String,
            material: payload["material"] as? String,
            materialOpacity: materialOpacity,
            shadowColor: shadowColor,
            shadowRadius: shadowRadius,
            shadowOffsetX: shadowOffsetX,
            shadowOffsetY: shadowOffsetY
        )
    }

    private static func optionalColor(_ value: Any?) -> OverlayRGBAColor?? {
        if value == nil || value is NSNull { return .some(nil) }
        guard let payload = value as? [String: Any],
              let red = finiteDouble(payload["red"]),
              let green = finiteDouble(payload["green"]),
              let blue = finiteDouble(payload["blue"]),
              let alpha = finiteDouble(payload["alpha"]) else { return nil }
        return .some(OverlayRGBAColor(red: red, green: green, blue: blue, alpha: alpha))
    }

    private static func optionalFiniteDouble(_ value: Any?) -> Double?? {
        if value == nil || value is NSNull { return .some(nil) }
        return finiteDouble(value).map { .some($0) }
    }

    private static func optionalFiniteDoubleArray(_ value: Any?) -> [Double]?? {
        if value == nil || value is NSNull { return .some(nil) }
        guard let values = value as? [NSNumber] else { return nil }
        let doubles = values.map(\.doubleValue)
        guard doubles.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return .some(doubles)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private func extensionURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = WebExtensionResourceHandler.scheme
        components.host = descriptor.identifier
        components.path = "/" + path
        return components.url!
    }

    private static func contentSizeObserverScript(handlerName: String) -> String {
        """
        (() => {
            var scheduled = false;
            const report = () => {
                if (scheduled) return;
                scheduled = true;
                requestAnimationFrame(() => {
                    scheduled = false;
                    const body = document.body;
                    const root = document.documentElement;
                    const height = Math.max(
                        body?.scrollHeight ?? 0,
                        body?.offsetHeight ?? 0,
                        root?.scrollHeight ?? 0,
                        root?.offsetHeight ?? 0
                    );
                    window.webkit.messageHandlers.\(handlerName).postMessage({ height });
                });
            };
            new ResizeObserver(report).observe(document.documentElement);
            report();
        })();
        """
    }
}

@MainActor
private final class WebExtensionCapabilityMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let broker: WebExtensionCapabilityBroker

    init(broker: WebExtensionCapabilityBroker) {
        self.broker = broker
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let identifier = body["capability"] as? String,
              let method = body["method"] as? String,
              let arguments = body["arguments"] as? [String: Any] else {
            return (nil, WebExtensionCapabilityError.invalidMessage.localizedDescription)
        }

        do {
            let value = try await broker.invoke(
                capability: identifier,
                method: method,
                arguments: arguments
            )
            return (value, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

private final class WebExtensionContentSizeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebExtensionRuntimeController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let number = body["height"] as? NSNumber else { return }
        Task { @MainActor [weak self] in
            self?.owner?.receiveContentHeight(CGFloat(truncating: number))
        }
    }
}

private final class WebExtensionOverlayMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebExtensionRuntimeController?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak self] in
            self?.owner?.receiveSelectionOverlayMessage(body)
        }
    }
}

private final class InteractiveWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
