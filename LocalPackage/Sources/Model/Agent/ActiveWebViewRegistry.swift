import Combine
import os
import WebUI
import WebKit

@MainActor
public final class ActiveWebViewRegistry: ObservableObject {
    public static let shared = ActiveWebViewRegistry()

    @Published public private(set) var webView: WKWebView? {
        didSet {
            #if DEBUG
            if let webView {
                logger.debug("Active web view set id=\(ObjectIdentifier(webView))")
            } else {
                logger.debug("Active web view cleared")
            }
            #endif
        }
    }

    private let logger = Logger(subsystem: "Agent", category: "WebViewStore")

    public init() {}

    public func set(_ webView: WKWebView?) {
        self.webView = webView
    }

    public func current() -> WKWebView? {
        webView
    }

    public func update(from proxy: WebViewProxy) {
        if let resolved = extractWebView(from: proxy) {
            set(resolved)
        }
    }

    public func currentIdentifier() -> ObjectIdentifier? {
        webView.map(ObjectIdentifier.init)
    }

    private func extractWebView(from proxy: WebViewProxy) -> WKWebView? {
        let mirror = Mirror(reflecting: proxy)
        for child in mirror.children {
            if child.label == "webView" {
                let innerMirror = Mirror(reflecting: child.value)
                for grandChild in innerMirror.children {
                    if grandChild.label == "wrappedValue", let wk = grandChild.value as? WKWebView {
                        return wk
                    }
                }
            }
        }
        return nil
    }
}
