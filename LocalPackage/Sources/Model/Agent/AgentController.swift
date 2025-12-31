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
    private var lastSnapshotHash: UInt64?
    private var lastSnapshotSize: CGSize?

    public enum RunState: String {
        case idle
        case running
        case paused
    }

    @Published public var goal: String
    @Published public var stepLimit: Int
    @Published public var isAgentModeEnabled: Bool
    @Published public var isRunning: Bool
    @Published public private(set) var runState: RunState
    @Published public private(set) var currentStep: Int
    @Published public private(set) var awaitingSafetyConfirmation: Bool
    @Published public private(set) var logs: [AgentLogEntry]
    @Published public private(set) var lastModelOutput: String?
    @Published public private(set) var pendingActions: [AgentAction]?
    @Published public private(set) var lastError: String?
    @Published public private(set) var selectedModel: String
    @Published public private(set) var availableModels: [String]
    @Published public var modelOverride: String
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
        self.runState = .idle
        self.currentStep = 0
        self.awaitingSafetyConfirmation = false
        self.logs = []
        self.lastModelOutput = nil
        self.pendingActions = nil
        self.lastError = nil
        self.apiKey = keychainStore.load(key: "geminiAPIKey") ?? ""
        self.selectedModel = "gemini-1.5-flash"
        self.availableModels = []
        self.modelOverride = "gemini-1.5-flash"
    }

    public func attach(proxy: WebViewProxy) {
        self.webViewProxy = proxy
        webView = extractWebView(from: proxy)
        Task { [weak self] in
            await self?.loadModels()
        }
    }

    public func toggleAgentMode(_ enabled: Bool) {
        isAgentModeEnabled = enabled
        appendLog(.init(date: Date(), kind: .info, message: "Agent Mode \(enabled ? "enabled" : "disabled")"))
        if !enabled { runState = .idle }
    }

    public func setGoal(_ newGoal: String) {
        goal = newGoal
    }

    public func step() {
        runTask?.cancel()
        awaitingSafetyConfirmation = false
        pendingActions = nil
        currentStep = 0
        runTask = Task { [weak self] in
            await self?.executeLoop(steps: 1)
        }
    }

    public func runAutomatically() {
        runTask?.cancel()
        awaitingSafetyConfirmation = false
        pendingActions = nil
        currentStep = 0
        runTask = Task { [weak self] in
            await self?.executeLoop(steps: self?.stepLimit ?? 1)
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        runState = .idle
        currentStep = 0
        awaitingSafetyConfirmation = false
        pendingActions = nil
        lastSnapshotHash = nil
        appendLog(.init(date: Date(), kind: .info, message: "Agent execution stopped"))
    }

    public func refreshModels() {
        Task { [weak self] in
            await self?.loadModels()
        }
    }

    public func applyModelOverride() {
        let trimmed = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard availableModels.contains(trimmed) else {
            lastError = "Model \(trimmed) not available"
            modelOverride = selectedModel
            appendLog(.init(date: Date(), kind: .error, message: lastError ?? ""))
            return
        }
        Task { [weak self] in
            await self?.updateSelectedModel(trimmed)
        }
    }

    public func resumeAfterSafetyCheck() {
        guard awaitingSafetyConfirmation, let actions = pendingActions else { return }
        awaitingSafetyConfirmation = false
        pendingActions = nil
        runTask?.cancel()
        runState = .running
        runTask = Task { [weak self] in
            await self?.execute(actions: actions)
            await self?.executeLoop(steps: (self?.stepLimit ?? 1))
        }
    }

    public func testGeminiConnection() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.performTestPrompt()
        }
    }

    public func describeScreen() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.performDescribePrompt()
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
        runState = .running
        lastError = nil
        defer { isRunning = false }

        for stepIndex in 0..<steps {
            if Task.isCancelled { return }
            currentStep = stepIndex + 1
            do {
                let response = try await generateActions(proxy: proxy)
                lastModelOutput = response.rawText
                appendLog(.init(date: Date(), kind: .model, message: response.rawText))
                response.warnings.forEach { warning in
                    appendLog(.init(date: Date(), kind: .warning, message: warning))
                }
                let actions = response.actions
                if actions.isEmpty {
                    appendLog(.init(date: Date(), kind: .warning, message: "No actions parsed from model output."))
                    if !response.rawText.isEmpty {
                        appendLog(.init(date: Date(), kind: .warning, message: "Raw model output retained without execution."))
                    }
                }
                let finished = response.isComplete || await execute(actions: actions)
                if finished {
                    appendLog(.init(date: Date(), kind: .result, message: "Agent marked goal complete"))
                    runState = .idle
                    return
                }
            } catch AgentError.cancelled {
                appendLog(.init(date: Date(), kind: .warning, message: "Cancelled"))
                runState = .idle
                return
            } catch AgentError.missingAPIKey {
                appendLog(.init(date: Date(), kind: .error, message: "Add a Gemini API key to run Agent Mode."))
                runState = .idle
                return
            } catch AgentError.missingWebView {
                appendLog(.init(date: Date(), kind: .error, message: "Unable to capture the current page."))
                runState = .idle
                return
            } catch {
                lastError = error.localizedDescription
                appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
                let nsError = error as NSError
                if nsError.code == 429 || nsError.code >= 500 {
                    runState = .paused
                    appendLog(.init(date: Date(), kind: .warning, message: "Rate limited or server error; paused"))
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(350))
            if stepIndex == steps - 1 {
                appendLog(.init(date: Date(), kind: .info, message: "Reached step limit"))
            }
        }
        runState = .idle
    }

    private func generateActions(proxy: WebViewProxy) async throws -> AgentResponse {
        guard !Task.isCancelled else { throw AgentError.cancelled }
        guard !apiKey.isEmpty else { throw AgentError.missingAPIKey }
        guard let snapshot = try await captureSnapshot() else { throw AgentError.missingWebView }
        if let lastHash = lastSnapshotHash, lastHash == snapshot.hash {
            appendLog(.init(date: Date(), kind: .info, message: "No visual change since last step; pausing"))
            return AgentResponse(rawText: "", actions: [], isComplete: false, warnings: [])
        }

        let context = recentContext()
        if !selectedModel.isEmpty {
            await geminiClient.setModel(selectedModel)
        }
        let output = try await geminiClient.generateActions(apiKey: apiKey, goal: goal, screenshotBase64: snapshot.encoded, context: context)
        let response = AgentParser.parse(from: output)
        lastSnapshotHash = snapshot.hash
        return response
    }

    private func performTestPrompt() async {
        guard !apiKey.isEmpty else {
            appendLog(.init(date: Date(), kind: .error, message: "Add a Gemini API key to run a test."))
            return
        }
        appendLog(.init(date: Date(), kind: .info, message: "Testing Gemini connectivity..."))
        do {
            let reply = try await geminiClient.testConnection(apiKey: apiKey)
            appendLog(.init(date: Date(), kind: .model, message: reply))
        } catch {
            lastError = error.localizedDescription
            appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
        }
    }

    private func performDescribePrompt() async {
        guard !apiKey.isEmpty else {
            appendLog(.init(date: Date(), kind: .error, message: "Add a Gemini API key to describe the screen."))
            return
        }
        do {
            guard let snapshot = try await captureSnapshot() else {
                appendLog(.init(date: Date(), kind: .error, message: "Unable to capture the current page."))
                return
            }
            let description = try await geminiClient.describeScreen(apiKey: apiKey, screenshotBase64: snapshot.encoded)
            appendLog(.init(date: Date(), kind: .model, message: description))
        } catch {
            lastError = error.localizedDescription
            appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
        }
    }

    private func captureSnapshot() async throws -> (encoded: String, viewport: CGSize, hash: UInt64)? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image, let data = image.pngData() {
                    let encoded = data.base64EncodedString()
                    continuation.resume(returning: (encoded, webView.bounds.size, data.fnv1a64))
                } else {
                    continuation.resume(throwing: AgentError.unableToCreateImage)
                }
            }
        }
        lastSnapshotSize = image.viewport
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
                runState = .paused
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
            await MainActor.run {
                proxy.load(request: URLRequest(url: url))
            }
            appendLog(.init(date: Date(), kind: .result, message: "Navigated to \(url.absoluteString)"))
        case .clickAt(let normalizedX, let normalizedY):
            let point = normalizedPoint(x: normalizedX, y: normalizedY, in: lastSnapshotSize ?? viewport)
            let script = """
            (() => {
                const element = document.elementFromPoint(\(point.x), \(point.y));
                if (!element) { return 'No element at point'; }
                element.click();
                return `Clicked ${element.tagName}`;
            })();
            """
            if let result = try? await MainActor.run(body: { try await proxy.evaluateJavaScript(script) as? String }) {
                appendLog(.init(date: Date(), kind: .result, message: result))
            }
        case .scroll(let deltaY):
            let script = "window.scrollBy(0, \(deltaY));"
            if let result = try? await MainActor.run(body: { try await proxy.evaluateJavaScript(script) as? String }) {
                appendLog(.init(date: Date(), kind: .result, message: result))
            }
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
            if let result = try? await MainActor.run(body: { try await proxy.evaluateJavaScript(script) as? String }) {
                appendLog(.init(date: Date(), kind: .result, message: result))
            }
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
            const title = document.title || '';
            const body = (document.body?.innerText || '').slice(0, 2000);
            return title + ' ' + body;
        })();
        """
        guard let text = try? await MainActor.run(body: { try await proxy.evaluateJavaScript(script) as? String }) else { return nil }
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

    private func loadModels() async {
        guard !apiKey.isEmpty else { return }
        appendLog(.init(date: Date(), kind: .info, message: "Refreshing Gemini models..."))
        do {
            let items = try await geminiClient.listModels(apiKey: apiKey)
            let names = items.compactMap { item -> String? in
                guard let methods = item.supportedGenerationMethods else { return nil }
                if methods.contains(where: { $0.lowercased().contains("generatecontent") }) { return item.name }
                return nil
            }
            await MainActor.run {
                self.availableModels = names
            }
            if let pick = await geminiClient.pickDefaultModel(from: items) {
                await updateSelectedModel(pick)
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
            }
            appendLog(.init(date: Date(), kind: .error, message: error.localizedDescription))
        }
    }

    private func updateSelectedModel(_ name: String) async {
        await geminiClient.setModel(name)
        await MainActor.run {
            self.selectedModel = name
            self.modelOverride = name
        }
        appendLog(.init(date: Date(), kind: .info, message: "Using model: \(name)"))
    }

    private func extractWebView(from proxy: WebViewProxy) -> WKWebView? {
        let mirror = Mirror(reflecting: proxy)
        for child in mirror.children {
            if child.label == "webView", let container = child.value as? AnyObject {
                let innerMirror = Mirror(reflecting: container)
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

private extension Data {
    var fnv1a64: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
