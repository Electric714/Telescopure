import Foundation

actor GeminiClient {
    struct RequestPayload: Encodable {
        let contents: [Content]
        let safetySettings: [SafetySetting] = []
    }

    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?
    }

    struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }

    struct ResponsePayload: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                let parts: [Part]
            }
            let content: Content
        }
        struct Part: Decodable { let text: String? }

        let candidates: [Candidate]?
    }

    struct SafetySetting: Encodable {
        let category: String
        let threshold: String
    }

    struct ModelList: Decodable {
        struct Item: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
        let models: [Item]?
    }

    private enum Constants {
        static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        static let preferredModels = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash", "gemini-3-pro"]
    }

    private let urlSession: URLSession
    private(set) var model: String

    init(urlSession: URLSession? = nil, model: String = "gemini-1.5-flash") {
        let configuration: URLSessionConfiguration
        if let urlSession {
            self.urlSession = urlSession
        } else {
            configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.urlSession = URLSession(configuration: configuration)
        }
        self.model = model
    }

    func setModel(_ name: String) {
        model = name
    }

    func listModels(apiKey: String) async throws -> [ModelList.Item] {
        var request = URLRequest(url: Constants.baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        return decoded.models ?? []
    }

    func pickDefaultModel(from available: [ModelList.Item]) -> String? {
        let names = available.map { $0.name }
        if let preferred = Constants.preferredModels.first(where: { names.contains($0) }) {
            return preferred
        }
        return available.first(where: { item in
            guard let methods = item.supportedGenerationMethods else { return false }
            let lower = item.name.lowercased()
            return methods.contains(where: { $0.lowercased().contains("generatecontent") }) && !lower.contains("embedding")
        })?.name ?? names.first
    }

    func generateActions(apiKey: String, goal: String, screenshotBase64: String, context: String) async throws -> String {
        let systemPrompt = """
        You are an agent controlling a mobile web browser inside a WKWebView. You must return STRICT JSON only.
        Always respond with an object like {"actions":[{"type":"click_at","x":100,"y":200}],"done":false}.
        Do not include explanations or markdown. Supported actions: navigate(url), click_at(x,y), scroll(deltaY), type(text), wait(ms), complete.
        Coordinates are normalized 0-1000 relative to the provided screenshot width/height. Include at least one action or mark done=true.
        """
        let userPrompt = """
Goal: \(goal)
Context: \(context)
Return JSON only for the next actions.
"""

        let contents: [Content] = [
            .init(role: "system", parts: [.init(text: systemPrompt, inlineData: nil)]),
            .init(role: "user", parts: [
                .init(text: userPrompt, inlineData: nil),
                .init(text: nil, inlineData: .init(mimeType: "image/png", data: screenshotBase64)),
            ]),
        ]

        return try await send(apiKey: apiKey, contents: contents)
    }

    func testConnection(apiKey: String) async throws -> String {
        let contents: [Content] = [
            .init(role: "user", parts: [.init(text: "Reply with exactly: OK", inlineData: nil)])
        ]
        return try await send(apiKey: apiKey, contents: contents)
    }

    func describeScreen(apiKey: String, screenshotBase64: String) async throws -> String {
        let contents: [Content] = [
            .init(role: "system", parts: [.init(text: "Describe the visible screen from the screenshot.", inlineData: nil)]),
            .init(role: "user", parts: [
                .init(text: "Describe what you see in one sentence.", inlineData: nil),
                .init(text: nil, inlineData: .init(mimeType: "image/png", data: screenshotBase64)),
            ]),
        ]
        return try await send(apiKey: apiKey, contents: contents)
    }

    private func send(apiKey: String, contents: [Content]) async throws -> String {
        let url = Constants.baseURL.appending(path: "models").appending(path: "\(model):generateContent")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let payload = RequestPayload(contents: contents)
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard 200..<300 ~= httpResponse.statusCode else {
                    if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                        throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Rate limited or server error"])
                    }
                    let message = String(data: data, encoding: .utf8) ?? ""
                    throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
                }

                let decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
                let text = decoded.candidates?.first?.content.parts.compactMap { $0.text }.joined(separator: "\n") ?? ""
                return text
            } catch {
                lastError = error
                if Task.isCancelled { throw URLError(.cancelled) }
                let nsError = error as NSError
                if attempt < 2 && (nsError.code == 429 || nsError.code >= 500) {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 300_000_000
                    try? await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}
