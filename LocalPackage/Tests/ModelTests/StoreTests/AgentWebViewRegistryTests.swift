#if canImport(WebKit) && canImport(UIKit)
@testable import Model
import UIKit
import WebKit
import XCTest

@MainActor
final class AgentWebViewRegistryTests: XCTestCase {
    func testControllerSharesRegistryWebView() async throws {
        let registry = ActiveWebViewRegistry()
        let controller = AgentController(webViewRegistry: registry)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let root = UIViewController()
        root.view = UIView(frame: window.bounds)

        let webView = WKWebView(frame: root.view.bounds)
        root.view.addSubview(webView)
        window.rootViewController = root
        window.makeKeyAndVisible()

        registry.set(webView)

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.activeWebViewIdentifier, ObjectIdentifier(webView))
        XCTAssertTrue(controller.isWebViewAvailable)
    }
}
#endif
