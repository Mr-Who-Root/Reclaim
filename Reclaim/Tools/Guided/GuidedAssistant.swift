import SwiftUI
import FoundationModels

/// The structured answer the on-device model returns.
@Generable
struct GuidedAssistantReply {
    @Guide(description: "A short, direct answer for the person. Two or three sentences at most. Never claim you moved, deleted or changed anything.")
    var answer: String

    @Guide(description: "Reference codes (like S3) of suggestions the person could add to their plan, copied exactly from the provided list. Empty if the question does not call for any.")
    var suggestionIDs: [String]
}

/// "Ask about this review": answers questions about a finished audit with Apple's on-device model.
/// Nothing leaves the Mac, and it can only recommend — never perform — actions.
@MainActor @Observable
final class GuidedAssistant {
    struct Message: Identifiable, Equatable {
        enum Role { case person, assistant, notice }
        let id = UUID()
        let role: Role
        let text: String
        /// Real suggestion ids the answer recommends adding to the plan.
        var suggestionIDs: [String] = []
    }

    private(set) var messages: [Message] = []
    private(set) var isResponding = false
    /// Bumped to make views re-read the model's availability.
    private(set) var availabilityCheck = 0

    private static let maxSuggestions = 40

    private static let instructions = """
    You are the assistant inside Reclaim, a Mac cleanup app.
    You help the person understand a completed, read-only audit of their Mac and decide what to put in a cleanup plan.
    Rules you must follow:
    - Answer in two or three short sentences.
    - Only talk about the suggestions listed in the prompt. Never invent files, sizes or reasons.
    - Never claim you performed an action. Only the person can approve a plan; Reclaim then moves approved items to the Trash, where they stay recoverable.
    - When it helps, recommend suggestions by their exact reference code (like S3) in suggestionIDs. Otherwise return no codes.
    - In the answer text, refer to items by their names, never by their reference codes.
    - If you are unsure whether something is safe to remove, say so and suggest checking it in Finder first.
    """

    /// Why the assistant can't run on this Mac right now, or nil when it can.
    var unavailableReason: String? {
        _ = availabilityCheck
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence, so the assistant can't run on it."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings to use the assistant."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "The assistant isn't available right now."
            }
        @unknown default:
            return "The assistant isn't available right now."
        }
    }

    func recheckAvailability() { availabilityCheck += 1 }

    func reset() {
        messages = []
        isResponding = false
    }

    func ask(_ question: String, suggestions: [CleanupSuggestion], decision: (CleanupSuggestion) -> GuidedDecision) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isResponding else { return }
        let history = messages.filter { $0.role != .notice }.suffix(4)
        messages.append(Message(role: .person, text: q))

        if let reason = unavailableReason {
            messages.append(Message(role: .notice, text: reason))
            return
        }

        // Short reference codes keep long file paths out of the model's limited context.
        let top = Array(suggestions.sorted { $0.bytes > $1.bytes }.prefix(Self.maxSuggestions))
        var codeToID: [String: String] = [:]
        var codeToName: [String: String] = [:]
        var lines: [String] = []
        for (i, s) in top.enumerated() {
            let code = "S\(i + 1)"
            codeToID[code] = s.id
            codeToName[code] = s.url.lastPathComponent
            let area = GuidedArea.area(for: s.tool)?.title ?? s.tool.title
            let state: String
            switch decision(s) {
            case .plan: state = "in plan"
            case .keep: state = "left unchanged"
            case .undecided: state = "undecided"
            }
            let reason = s.reason.count > 110 ? String(s.reason.prefix(110)) + "…" : s.reason
            lines.append("\(code) | \(area) | \(s.title) | \(Fmt.bytes(s.bytes)) | \(s.confidence.label) | \(state) | \(reason)")
        }

        let recent = history.map { "\($0.role == .person ? "Person" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Suggestions currently in the review (\(top.count) of \(suggestions.count), largest first):
        \(lines.isEmpty ? "(none)" : lines.joined(separator: "\n"))

        Recent conversation:
        \(recent.isEmpty ? "(none)" : recent)

        Person's question: \(q)
        """

        isResponding = true
        defer { isResponding = false }
        do {
            // A fresh session per question keeps the context small; recent turns are included as text.
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: prompt, generating: GuidedAssistantReply.self, includeSchemaInPrompt: true)
            var ids: [String] = []
            for raw in response.content.suggestionIDs {
                let code = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
                if let id = codeToID[code], !ids.contains(id) { ids.append(id) }
            }
            let answer = Self.replacingCodes(in: response.content.answer, names: codeToName)
            messages.append(Message(role: .assistant, text: answer, suggestionIDs: ids))
        } catch let error as LanguageModelSession.GenerationError {
            messages.append(Message(role: .notice, text: Self.describe(error)))
        } catch {
            messages.append(Message(role: .notice, text: "The assistant couldn't answer that: \(error.localizedDescription)"))
        }
    }

    /// Swaps any reference codes the model left in its answer ("S3") for the item's name.
    private static func replacingCodes(in text: String, names: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bS([0-9]{1,3})\b"#) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let code = ns.substring(with: match.range)
            guard let name = names[code], let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: name)
        }
        return result
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "That needed more context than the on-device model allows. Try a narrower filter or a shorter question."
        case .guardrailViolation, .refusal:
            return "The on-device model declined to answer that. Try rephrasing the question."
        case .assetsUnavailable:
            return "The on-device model isn't ready yet. Try again shortly."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support this language yet."
        case .rateLimited, .concurrentRequests:
            return "The on-device model is busy. Try again in a moment."
        default:
            return "The assistant couldn't answer that: \(error.localizedDescription)"
        }
    }
}
