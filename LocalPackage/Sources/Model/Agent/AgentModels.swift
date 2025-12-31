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
    public let warnings: [String]
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
            return AgentResponse(rawText: raw, actions: [], isComplete: false, warnings: ["Model response was not JSON"])
        }

        let decoder = JSONDecoder()
        let envelope: AgentActionEnvelope?
        do {
            envelope = try decoder.decode(AgentActionEnvelope.self, from: jsonData)
        } catch {
            return AgentResponse(rawText: raw, actions: [], isComplete: false, warnings: ["Failed to decode JSON: \(error.localizedDescription)"])
        }

        let dtos = envelope?.actions ?? envelope?.action ?? []
        var warnings: [String] = []
        let actions = dtos.compactMap { dto -> AgentAction? in
            switch dto.type.lowercased() {
            case "navigate":
                guard let urlString = dto.url, let url = URL(string: urlString) else {
                    warnings.append("navigate missing url")
                    return nil
                }
                return .navigate(url)
            case "click_at", "clickat", "click":
                guard let x = dto.x, let y = dto.y else {
                    warnings.append("click_at missing x/y")
                    return nil
                }
                return .clickAt(normalizedX: x, normalizedY: y)
            case "scroll":
                if let delta = dto.deltaY ?? dto.y {
                    return .scroll(deltaY: delta)
                }
                warnings.append("scroll missing deltaY")
                return nil
            case "type", "input":
                guard let text = dto.text else {
                    warnings.append("type missing text")
                    return nil
                }
                return .type(text: text)
            case "wait", "sleep":
                if let ms = dto.ms ?? Int(dto.x ?? 0) {
                    return .wait(milliseconds: ms)
                }
                warnings.append("wait missing ms")
                return nil
            case "complete", "done":
                return .complete
            default:
                warnings.append("unknown action type \(dto.type)")
                return nil
            }
        }

        let completionFlag = envelope?.complete == true || envelope?.done == true || (envelope?.status?.lowercased().contains("complete") == true)
        return AgentResponse(rawText: raw, actions: actions, isComplete: completionFlag || actions.contains(.complete), warnings: warnings)
    }

    private static func extractJSON(from text: String) -> Data? {
        if let data = extractFromFences(text) ?? extractInlineJSON(text) {
            return data
        }
        return nil
    }

    private static func extractFromFences(_ text: String) -> Data? {
        let pattern = "```(?:json)?\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        let nsText = text as NSString
        let jsonString = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonString.data(using: .utf8)
    }

    private static func extractInlineJSON(_ text: String) -> Data? {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let jsonRange = start...end
            let jsonString = text[jsonRange]
            return jsonString.data(using: .utf8)
        }
        return nil
    }
}
