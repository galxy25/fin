// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// The lock-screen headline for a `request_input` question: what Fin actually needs,
/// in a few words, instead of a bare "Fin needs your input".
///
/// Levi (2026-10-22): "make the needs your input actually descriptive of what is
/// needed". A model writes the headline — the daemon asks its own brain, the app asks
/// Apple's on-device model — and everything here is the model-free part both share:
/// the instruction, the cleanup of whatever comes back, and the deterministic
/// fallback that is used whenever no model answers in time. A push must never wait on,
/// or be lost to, a model that is unloaded, busy, or slow.
public enum InputHeadline {
    /// Longer than this and the lock screen truncates it anyway.
    public static let maxCharacters = 60

    /// How long a caller should wait for a model before falling back. The question is
    /// time-sensitive; a headline is decoration.
    public static let modelTimeoutSeconds: Double = 20

    public static let instruction = """
        You write notification titles. The user's terminal agent is blocked and asked \
        the user the question below. Reply with ONE short title (3 to 8 words, no \
        quotes, no trailing period) that says what decision or information is needed, \
        e.g. "Pick a branch for the rebase" or "Approve deleting build/". Reply with the \
        title only.
        """

    /// Cleans a model's reply into a usable title, or nil when it isn't one (empty,
    /// a refusal-length essay, a reasoning dump). Callers fall back on nil.
    public static func sanitize(_ raw: String) -> String? {
        var text = raw
        // Reasoning models may leak a think block even with a tiny token budget.
        if let close = text.range(of: "</think>") {
            text = String(text[close.upperBound...])
        } else if text.contains("<think>") {
            return nil  // ran out of budget mid-thought: no title in there
        }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var title = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#“”‘’ "))
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        while title.hasSuffix(".") { title.removeLast() }
        guard !title.isEmpty, title.split(separator: " ").count <= 12 else { return nil }
        return clipped(title)
    }

    /// The model-free headline: the question's first sentence, clipped. Never empty —
    /// an empty question still says what kind of thing is pending.
    public static func fallback(question: String) -> String {
        let flattened = question
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "Fin needs your input" }
        var first = flattened
        if let end = flattened.firstIndex(where: { "?.!".contains($0) }) {
            first = String(flattened[...end])
        }
        while first.hasSuffix(".") { first.removeLast() }
        return clipped(first)
    }

    static func clipped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = text.prefix(maxCharacters - 1)
        let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return atWord + "…"
    }

    /// Runs `model`, bounded by `timeoutSeconds`, and returns its sanitized title —
    /// or the fallback on timeout, error, or an unusable reply. Never throws, never
    /// waits longer than the timeout.
    public static func generate(
        question: String,
        timeoutSeconds: Double = modelTimeoutSeconds,
        model: @escaping @Sendable (String) async throws -> String
    ) async -> String {
        let fallbackTitle = fallback(question: question)
        let result = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { (try? await model(question)).flatMap(sanitize) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return result ?? fallbackTitle
    }
}
