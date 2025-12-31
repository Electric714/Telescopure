import Foundation
import WebUI
import WebKit

@MainActor
public final class AgentController: ObservableObject {
    private enum AgentError: LocalizedError {
        case missingAPIKey
        case missingWebView
        case unableToCreateImage
        case cancelled
    }

    private let geminiClient: GeminiClient
    private let keychainStore = KeychainStore()

    private weak var webViewProxy: WebViewProxy?
    private weak var webView: WKWebView?
    private var runTask: Task<Void, Never>?

    @Published public var goal: String
    @Published public var stepLimit: Int
    @Published public var isAgentModeEnabled: Bool
    @Published public var isRunning: Bool
    @Published public private(set) var awaitingSafetyConfirmation: Bool
    @Published public private(set) var logs: [AgentLogEntry]
    @Published public private(set) var lastModelOutput: String?
    @Published public private(set) var pendingActions: [AgentAction]?
    @Published public var apiKey: String {
        didSet {
            _ = keychainStore.save(key: "geminiAPIKey", value: apiKey)
        }
    }

    public init(goal: String = "", stepLimit: Int = 10, isAgentModeEnabled: Bool = false) {
        self.geminiClient = GeminiClient()
        self.goal = goal
        self.stepLimit = max(1, stepLimit)
        self.isAgentModeEnabled = isAgentModeEnabled
        self.isRunning = false
        self.awaitingSafetyConfirmation = false
        self.logs = []
        self.lastModelOutput = nil
        self.pendingActions = nil
        self.apiKey = keychainStore.load(key: "geminiAPIKey") ?? ""
    }

    public func attach(proxy: WebViewProxy) {
        self.webViewProxy = proxy
        webView = extractWebView(from: proxy)
    }

    public func toggleAgentMode(_ enabled: Bool) {
        isAgentModeEnabled = enabled
        appendLog(.init(date: Date(), kind: .info, message: "Agent Mode \(enabled ? "enabled" : "disabled")"))
    }

    public func setGoal(_ newGoal: String) {
        goal = newGoal
    }

    public func step() {
        runTask?.cancel()
        awaitingSafetyConfirmation = false
        pendingActions = nil
        runTask = Task { [weak self] in
            await self?.executeLoop(steps: 1)
        }
    }

    public func runAutomatically() {
        runTask?.cancel()
        awaitingSafetyConfirmation = false
        pendingActions = nil
        runTask = Task { [weak self] in
            await self?.executeLoop(steps: self?.stepLimit ?? 1)
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        awaitingSafetyConfirmation = false
        pendingActions = nil
        appendLog(.init(date: Date(), kind: .info, message: "Agent execution stopped"))
    }

    public func resumeAfterSafetyCheck() {
        guard awaitingSafetyConfirmation, let actions = pendingActions else { return }
        awaitingSafetyConfirmation = false
        pendingActions = nil
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.execute(actions: actions)
            await self?.executeLoop(steps: (self?.stepLimit ?? 1))
        }
    }

    private func executeLoop(steps: Int) async {
        guard isAgentModeEnabled else {
            appendLog(.init(date: Date(), kind: .warning, message: "Enable Agent Mode to start"))
            return
        }
        guard !goal.isEmpty else {
            appendLog(.init(date: Date(), kind: .warning, message: "Set a goal for the agent"))
            return
        }
        guard let proxy = webViewProxy else {
            appendLog(.init(date: Date(), kind: .error, message: "Web view is not ready"))
            return
        }
        isRunning = true
        defer { isRunning = false }

        for stepIndex in 0..<steps {
            if Task.isCancelled { return }
            do {
                let response = try await generateActions(proxy: proxy)
                lastModelOutput = response.rawText
                appendLog(.init(date: Date(), kind: .model, message: response.rawText))
                let actions = response.actions
                if actions.isEmpty {
                    appendLog(.init(date: Date(), kind: .warning, message: "No actions returned"))
                }
                let finished: Bool
                if response.isComplete {
                    finished = true
                } else {
                    finished = await execute(actions: actions)
                }
                if finished {
                    appendLog(.init(date: Date(), kind: .result, message: "Agent marked goal complete"))
                    return
                }
            } catch AgentError.cancelled {
                appendLog(.init(date: Date(), kind: .warning, message: "Cancelled"))
                return
            } catch AgentError.missingAPIKey {
                appendLog(.init(date: Date(), kind: .error, message: "Add a Gemini API key to run Agent Mode."))
                return
            } catch AgentError.missingWebView {
                appendLog(.init(date: Date(), kind: .error, message: "Unable to capture the current page."))
                return
            } catch {
                appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
            }
            if stepIndex == steps - 1 {
                appendLog(.init(date: Date(), kind: .info, message: "Reached step limit"))
            }
        }
    }

    private func generateActions(proxy: WebViewProxy) async throws -> AgentResponse {
        guard !Task.isCancelled else { throw AgentError.cancelled }
        guard !apiKey.isEmpty else { throw AgentError.missingAPIKey }
        guard let snapshot = try await captureSnapshot() else { throw AgentError.missingWebView }

        let context = recentContext()
        let output = try await geminiClient.generateActions(apiKey: apiKey, goal: goal, screenshotBase64: snapshot.encoded, context: context)
        let response = AgentParser.parse(from: output)
        return response
    }

    private func captureSnapshot() async throws -> (encoded: String, viewport: CGSize)? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image: (encoded: String, viewport: CGSize) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(encoded: String, viewport: CGSize), Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image, let data = image.pngData() {
                    let encoded = data.base64EncodedString()
                    continuation.resume(returning: (encoded, webView.bounds.size))
                } else {
                    continuation.resume(throwing: AgentError.unableToCreateImage)
                }
            }
        }
        return image
    }

    private func execute(actions: [AgentAction]) async -> Bool {
        guard !Task.isCancelled else { return true }
        guard let proxy = webViewProxy else { return true }
        guard let viewport = webView?.bounds.size else { return true }

        for (index, action) in actions.enumerated() {
            if Task.isCancelled { return true }
            if awaitingSafetyConfirmation { return true }
            if let warning = await scanForRisk(proxy: proxy) {
                appendLog(.init(date: Date(), kind: .warning, message: warning))
                awaitingSafetyConfirmation = true
                pendingActions = Array(actions.suffix(from: index))
                return true
            }
            appendLog(.init(date: Date(), kind: .action, message: "Executing: \(actionDescription(action))"))
            do {
                let completed = try await execute(action: action, viewport: viewport, proxy: proxy)
                if completed { return true }
            } catch {
                appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
            }
        }
        return false
    }

    private func execute(action: AgentAction, viewport: CGSize, proxy: WebViewProxy) async throws -> Bool {
        switch action {
        case .navigate(let url):
            proxy.load(request: URLRequest(url: url))
            appendLog(.init(date: Date(), kind: .result, message: "Navigated to \(url.absoluteString)"))
        case .clickAt(let normalizedX, let normalizedY):
            let point = normalizedPoint(x: normalizedX, y: normalizedY, in: viewport)
            let script = """
            (() => {
                const element = document.elementFromPoint(\(point.x), \(point.y));
                if (!element) { return 'No element at point'; }
                element.click();
                return `Clicked ${element.tagName}`;
            })();
            """
            _ = try? await proxy.evaluateJavaScript(script)
        case .scroll(let deltaY):
            let script = "window.scrollBy(0, \(deltaY));"
            _ = try? await proxy.evaluateJavaScript(script)
        case .type(let text):
            let escaped = javascriptEscape(text)
            let script = """
            (() => {
                const target = document.activeElement;
                if (!target) { return 'No active element'; }
                const value = (target.value || '') + \(escaped);
                target.value = value;
                target.dispatchEvent(new Event('input', { bubbles: true }));
                return 'Typed into active element';
            })();
            """
            _ = try? await proxy.evaluateJavaScript(script)
        case .wait(let ms):
            try await Task.sleep(for: .milliseconds(ms))
        case .complete:
            return true
        }
        return false
    }

    private func normalizedPoint(x: Double, y: Double, in viewport: CGSize) -> CGPoint {
        let boundedX = max(0, min(1000, x))
        let boundedY = max(0, min(1000, y))
        let px = CGFloat(boundedX) / 1000 * viewport.width
        let py = CGFloat(boundedY) / 1000 * viewport.height
        return CGPoint(x: px, y: py)
    }

    private func scanForRisk(proxy: WebViewProxy) async -> String? {
        let keywords = ["purchase", "buy", "pay", "send", "delete", "confirm", "submit order"]
        let joined = keywords.joined(separator: "|")
        let script = """
        (() => {
            const text = (document.title || '') + ' ' + (document.body?.innerText || '');
            return text.slice(0, 8000);
        })();
        """
        guard let text = try? await proxy.evaluateJavaScript(script) as? String else { return nil }
        let lower = text.lowercased()
        if keywords.contains(where: { lower.contains($0) }) {
            return "Sensitive keyword detected (\(joined)). Confirm to continue."
        }
        return nil
    }

    private func actionDescription(_ action: AgentAction) -> String {
        switch action {
        case .navigate(let url): return "navigate(\(url.absoluteString))"
        case .clickAt(let x, let y): return "click_at(\(x),\(y))"
        case .scroll(let delta): return "scroll(\(delta))"
        case .type(let text): return "type(\(text.prefix(30)))"
        case .wait(let ms): return "wait(\(ms)ms)"
        case .complete: return "complete"
        }
    }

    private func javascriptEscape(_ text: String) -> String {
        let json = try? JSONSerialization.data(withJSONObject: [text], options: [])
        let literal = String(data: json ?? Data(), encoding: .utf8) ?? "\"\""
        if literal.count >= 2 {
            let start = literal.index(after: literal.startIndex)
            let end = literal.index(before: literal.endIndex)
            let range = start..<end
            let content = literal[range]
            return "\"\(content)\""
        }
        return "\"\""
    }

    private func recentContext() -> String {
        let latest = logs.suffix(6).map { "[\($0.kind.rawValue)] \($0.message)" }
        return latest.joined(separator: "\n")
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

    private func appendLog(_ entry: AgentLogEntry) {
        logs.append(entry)
    }
}
