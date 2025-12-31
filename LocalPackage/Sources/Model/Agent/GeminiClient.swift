import Foundation

struct GeminiClient {
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

    let urlSession: URLSession
    let model: String

    init(urlSession: URLSession = .shared, model: String = "gemini-1.5-flash-latest") {
        self.urlSession = urlSession
        self.model = model
    }

    func generateActions(apiKey: String, goal: String, screenshotBase64: String, context: String) async throws -> String {
        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are an agent controlling a mobile web browser. Respond ONLY with JSON describing the next actions.
        Use normalized coordinates (0-1000) matching the screenshot.
        Supported actions: navigate(url), click_at(x,y), scroll(deltaY), type(text), wait(ms).
        Return the shape: {"actions":[{"type":"click_at","x":100,"y":200}],"done":false}. Mark done/complete when the goal is finished.
        """

        let payload = RequestPayload(contents: [
            .init(role: "user", parts: [
                .init(text: systemPrompt + "\nGoal:" + goal + "\nContext:" + context, inlineData: nil),
                .init(text: nil, inlineData: .init(mimeType: "image/png", data: screenshotBase64)),
            ]),
        ])
        let encoder = JSONEncoder()
        let body = try encoder.encode(payload)
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GeminiClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
        let text = decoded.candidates?.first?.content.parts.compactMap { $0.text }.joined(separator: "\n") ?? ""
        return text
    }
}
