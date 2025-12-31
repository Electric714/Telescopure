import WebUI
import WebKit

@MainActor
public final class ActiveWebViewRegistry {
    public static let shared = ActiveWebViewRegistry()

    private init() {}

    weak var webView: WKWebView?

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
