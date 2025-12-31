import Foundation
import CoreGraphics

public enum AgentAction: Equatable, Sendable {
    case navigate(URL)
    case clickAt(normalizedX: Double, normalizedY: Double)
    case scroll(deltaY: Double)
    case type(text: String)
    case wait(milliseconds: Int)
    case complete
}

public struct AgentResponse: Sendable {
    public let rawText: String
    public let actions: [AgentAction]
    public let isComplete: Bool
}

public struct AgentLogEntry: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case info
        case model
        case action
        case result
        case error
        case warning
    }

    public let id = UUID()
    public let date: Date
    public let kind: Kind
    public let message: String
}

struct AgentActionDTO: Decodable {
    let type: String
    let url: String?
    let x: Double?
    let y: Double?
    let deltaY: Double?
    let text: String?
    let ms: Int?
}

struct AgentActionEnvelope: Decodable {
    let actions: [AgentActionDTO]?
    let action: [AgentActionDTO]?
    let complete: Bool?
    let done: Bool?
    let status: String?
}

enum AgentParser {
    static func parse(from raw: String) -> AgentResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = extractJSON(from: trimmed) else {
            return AgentResponse(rawText: raw, actions: [], isComplete: false)
        }

        let decoder = JSONDecoder()
        let envelope: AgentActionEnvelope?
        do {
            envelope = try decoder.decode(AgentActionEnvelope.self, from: jsonData)
        } catch {
            return AgentResponse(rawText: raw, actions: [], isComplete: false)
        }

        let dtos = envelope?.actions ?? envelope?.action ?? []
        let actions = dtos.compactMap { dto -> AgentAction? in
            switch dto.type.lowercased() {
            case "navigate":
                guard let urlString = dto.url, let url = URL(string: urlString) else { return nil }
                return .navigate(url)
            case "click_at", "clickat", "click":
                guard let x = dto.x, let y = dto.y else { return nil }
                return .clickAt(normalizedX: x, normalizedY: y)
            case "scroll":
                if let delta = dto.deltaY ?? dto.y { return .scroll(deltaY: delta) }
                return nil
            case "type", "input":
                guard let text = dto.text else { return nil }
                return .type(text: text)
            case "wait", "sleep":
                let ms = dto.ms ?? Int(dto.x ?? 0)
                return .wait(milliseconds: ms)
            case "complete", "done":
                return .complete
            default:
                return nil
            }
        }

        let completionFlag = envelope?.complete == true || envelope?.done == true || (envelope?.status?.lowercased().contains("complete") == true)
        return AgentResponse(rawText: raw, actions: actions, isComplete: completionFlag || actions.contains(.complete))
    }

    private static func extractJSON(from text: String) -> Data? {
        if let range = text.range(of: "```") {
            let suffix = text[range.upperBound...]
            if let endRange = suffix.range(of: "```") {
                var jsonString = String(suffix[suffix.startIndex..<endRange.lowerBound])
                jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
                if jsonString.lowercased().hasPrefix("json") {
                    jsonString = String(jsonString.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return jsonString.data(using: .utf8)
            }
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let jsonRange = start...end
            let jsonString = text[jsonRange]
            return jsonString.data(using: .utf8)
        }
        return nil
    }
}
