import AppKit
import SwiftUI
import WebKit

/// Cached offline KaTeX bundle resources loaded from `Bundle.module`.
public final class KatexResources: Sendable {
    public static let shared = KatexResources()

    public let css: String
    public let js: String
    public let baseURL: URL?

    private init() {
        let bundle = Bundle.module
        self.baseURL = bundle.resourceURL

        if let cssURL = bundle.url(forResource: "katex.min", withExtension: "css"),
           let rawCSS = try? String(contentsOf: cssURL, encoding: .utf8) {
            // SwiftPM `.process("Resources")` flattens font files into `Contents/Resources/`
            // alongside `katex.min.css`. Rewrite `url(fonts/` when `fonts/` subdir isn't present.
            let hasFontsSubdir = bundle.resourceURL
                .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("fonts").path) }
                ?? false
            self.css = hasFontsSubdir
                ? rawCSS
                : rawCSS.replacingOccurrences(of: "url(fonts/", with: "url(")
        } else {
            self.css = ""
        }

        if let jsURL = bundle.url(forResource: "katex.min", withExtension: "js"),
           let rawJS = try? String(contentsOf: jsURL, encoding: .utf8) {
            self.js = rawJS
        } else {
            self.js = ""
        }
    }

    public var isAvailable: Bool {
        !css.isEmpty && !js.isEmpty
    }
}

/// Pre-warms a single WebKit process at app launch so focal `MathView` instances render without cold-start delay.
@MainActor
public enum WebKitPrewarmer {
    private static var warmedWebView: WKWebView?

    public static func warmUp() {
        guard warmedWebView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: KatexResources.shared.baseURL)
        warmedWebView = webView
    }
}

/// Self-sizing, offline KaTeX + Markdown SwiftUI view backed by `WKWebView`.
/// Loads the KaTeX shell once and applies incremental updates via `window.lunarUpdate(payload)` without flicker.
public struct MathView: View {
    public let content: String
    public var fontFamily: String
    public var fontSize: String
    public var compact: Bool
    public var minHeight: CGFloat
    public var maxHeight: CGFloat?

    @State private var measuredHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(
        content: String,
        fontFamily: String = "serif",
        fontSize: String = "base",
        compact: Bool = false,
        minHeight: CGFloat = 22,
        maxHeight: CGFloat? = nil
    ) {
        self.content = content
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.compact = compact
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        _measuredHeight = State(initialValue: minHeight)
    }

    private var effectiveHeight: CGFloat {
        let clamped = max(minHeight, measuredHeight)
        if let maxHeight {
            return min(clamped, maxHeight)
        }
        return clamped
    }

    public var body: some View {
        MathWebViewRepresentable(
            content: content,
            colorScheme: colorScheme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            compact: compact,
            onHeightChange: { newHeight in
                guard newHeight > 0, abs(newHeight - measuredHeight) > 2.0 else { return }
                measuredHeight = newHeight
            }
        )
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: effectiveHeight)
        .clipped()
    }
}

private struct MathWebViewRepresentable: NSViewRepresentable {
    let content: String
    let colorScheme: ColorScheme
    let fontFamily: String
    let fontSize: String
    let compact: Bool
    let onHeightChange: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let proxy = WeakScriptMessageProxy(coordinator: context.coordinator)
        contentController.add(proxy, name: "lunarHeight")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.websiteDataStore = .nonPersistent()

        let webView = ForwardingWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.alphaValue = 0
        webView.allowsMagnification = false
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false

        loadOrUpdate(webView: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        loadOrUpdate(webView: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.debounceTask?.cancel()
        coordinator.debounceTask = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lunarHeight")
        webView.navigationDelegate = nil
    }

    private func loadOrUpdate(webView: WKWebView, coordinator: Coordinator) {
        let renderKey = RenderKey(
            content: content,
            isDark: colorScheme == .dark,
            fontFamily: fontFamily,
            fontSize: fontSize,
            compact: compact
        )
        guard coordinator.lastRenderKey != renderKey else { return }
        coordinator.lastRenderKey = renderKey

        let parsed = MathParser.parse(content)
        let resources = KatexResources.shared

        // Initial shell load: load HTML once while hidden, then reveal on didFinish.
        if !coordinator.didStartInitialLoad {
            coordinator.didStartInitialLoad = true
            let html = MathParser.buildDocumentHTML(
                parsed: parsed,
                colorScheme: colorScheme,
                fontFamily: fontFamily,
                fontSize: fontSize,
                compact: compact,
                katexCSS: resources.css,
                katexJS: resources.js
            )
            webView.loadHTMLString(html, baseURL: resources.baseURL)
            return
        }

        let payloadJSON = MathParser.buildUpdatePayloadJSON(
            parsed: parsed,
            colorScheme: colorScheme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            compact: compact
        )

        // If the initial HTML shell is still loading, queue the latest payload for immediate application in didFinish.
        guard coordinator.isShellLoaded else {
            coordinator.pendingPayloadJSON = payloadJSON
            return
        }

        // Debounce live keystroke updates cleanly (60ms) without blanking or reloading the shell.
        coordinator.debounceTask?.cancel()
        coordinator.debounceTask = Task { @MainActor [weak coordinator, weak webView] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let coordinator, let webView else { return }
            coordinator.applyPayload(payloadJSON, to: webView)
        }
    }

    struct RenderKey: Equatable {
        let content: String
        let isDark: Bool
        let fontFamily: String
        let fontSize: String
        let compact: Bool
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRenderKey: RenderKey? {
            didSet {
                if oldValue != lastRenderKey {
                    recentHeightsForKey.removeAll()
                }
            }
        }
        var didStartInitialLoad = false
        var isShellLoaded = false
        var pendingPayloadJSON: String?
        var debounceTask: Task<Void, Never>?
        var onHeightChange: (CGFloat) -> Void
        private var recentHeightsForKey: [CGFloat] = []

        init(onHeightChange: @escaping @MainActor (CGFloat) -> Void) {
            self.onHeightChange = onHeightChange
        }

        func handleHeightMessage(_ body: Any) {
            let newHeight: CGFloat?
            if let num = body as? NSNumber {
                newHeight = CGFloat(num.doubleValue)
            } else if let dbl = body as? Double {
                newHeight = CGFloat(dbl)
            } else {
                newHeight = nil
            }
            guard let height = newHeight, height > 0 else { return }

            // Break layout oscillation loops where a scrollbar threshold flips height A <-> B for identical content.
            if recentHeightsForKey.count >= 4,
               let prev = recentHeightsForKey.last,
               abs(prev - height) > 1,
               recentHeightsForKey.dropLast().contains(where: { abs($0 - height) < 1.5 }) {
                return
            }
            recentHeightsForKey.append(height)
            if recentHeightsForKey.count > 6 {
                recentHeightsForKey.removeFirst(recentHeightsForKey.count - 6)
            }
            onHeightChange(height)
        }

        func applyPayload(_ payloadJSON: String, to webView: WKWebView) {
            let safeJSON = payloadJSON
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            let js = "if (typeof window.lunarUpdate === 'function') { window.lunarUpdate(\(safeJSON)); } Math.ceil(document.getElementById('lunar-root')?.getBoundingClientRect().height || 0);"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                let height = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                Task { @MainActor [weak self] in
                    if height > 0 {
                        self?.onHeightChange(height)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellLoaded = true
            if let pending = pendingPayloadJSON {
                pendingPayloadJSON = nil
                let safeJSON = pending
                    .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                    .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
                let js = "if (typeof window.lunarUpdate === 'function') { window.lunarUpdate(\(safeJSON)); } Math.ceil(document.getElementById('lunar-root')?.getBoundingClientRect().height || 0);"
                webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
                    let height = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                    Task { @MainActor [weak self, weak webView] in
                        if height > 0 {
                            self?.onHeightChange(height)
                        }
                        webView?.alphaValue = 1
                    }
                }
            } else {
                webView.evaluateJavaScript(
                    "Math.ceil(document.getElementById('lunar-root')?.getBoundingClientRect().height || 0)"
                ) { [weak self, weak webView] result, _ in
                    let height = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                    Task { @MainActor [weak self, weak webView] in
                        if height > 0 {
                            self?.onHeightChange(height)
                        }
                        webView?.alphaValue = 1
                    }
                }
            }
        }
    }
}

/// Prevents `WKUserContentController` from strongly retaining `Coordinator`.
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: MathWebViewRepresentable.Coordinator?

    init(coordinator: MathWebViewRepresentable.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        Task { @MainActor [weak coordinator] in
            coordinator?.handleHeightMessage(body)
        }
    }
}

/// Transparent `WKWebView` that passes vertical scroll events up to parent SwiftUI `ScrollView` / `List`
/// and disables scroll bounce/scrollbars.
private final class ForwardingWKWebView: WKWebView {
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
