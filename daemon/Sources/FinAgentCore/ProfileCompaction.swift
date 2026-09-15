import Foundation

/// The cumulative user profile's compaction contract, shared by the daemon
/// (`DaemonMemoryConsolidator`) and the app (`AgentRuntime.consolidateMemoriesIfDue`)
/// so the ONE document both rewrite is rewritten by one rule.
///
/// Why this exists: the profile used to be an undated free-text blob, re-fed
/// verbatim on every pass under a "merge" instruction, guarded by a rule that
/// rejected any rewrite shrinking it past 30%. Nothing in that loop knew how old
/// a fact was, so "troubleshooting iPad connectivity" rode along for weeks after
/// the work ended — pruning it looked to the guard like a bad model reply.
/// Every input here is dated, current work is explicitly time-boxed, and a
/// well-formed rewrite may shrink as far as it likes.
public enum ProfileCompaction {
    /// Hard bound on the stored profile; the prompt asks for less.
    public static let maxStoredCharacters = 2000
    public static let requestedCharacters = 1500
    /// "Current work" means confirmed within this many days. Older items are
    /// demoted to past work or dropped — the model is told so in the instruction.
    public static let currentWorkWindowDays = 7

    /// The section headings the instruction asks for, verbatim. `acceptable`
    /// treats a candidate carrying at least two of them as structurally sound.
    public static let sectionHeadings = ["Current work", "Past work", "Environment", "Preferences"]

    /// One labeled block of non-conversational observations ("Terminal panes right
    /// now", "Other computers right now", "Session activity") so the model can
    /// tell "the user told me this" apart from "Fin observed this".
    public struct ObservedSection: Equatable, Sendable {
        public var title: String
        public var lines: [String]
        public init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    /// One recent conversation to fold in. `date` is when it was last updated.
    public struct Conversation: Equatable, Sendable {
        public var title: String
        public var date: Date?
        public var content: String
        public init(title: String, date: Date?, content: String) {
            self.title = title
            self.date = date
            self.content = content
        }
    }

    /// The first characters of the ANSWER, handed to the model as an already-started
    /// assistant turn.
    ///
    /// THIS IS THE DIFFERENCE BETWEEN A PROFILE AND NOTHING AT ALL. Gemma 4 is a reasoning
    /// model, and asked to "rewrite the user profile" it deliberates without bound: measured
    /// on 2026-09-15 it spent 2045 of 2048 output tokens thinking and emitted three tokens
    /// of content, then 6144 tokens over 523 seconds and emitted none. It was not failing
    /// the task — it was caught mid-self-review ("Wait, let me double check the Current work
    /// date logic") every time. Raising the budget does not help; the endpoint ignores
    /// `reasoning_effort` and `enable_thinking`, and LM Studio has no load-time switch.
    ///
    /// Prefilling the assistant turn ends the question. The model is no longer deciding
    /// whether to begin; it is continuing a line that has already begun. Same model, same
    /// 8192 context, same prompt: `reasoning_tokens: 0`, `finish_reason: stop`, 1632
    /// characters of correct profile, first try.
    ///
    /// The model's reply CONTINUES this text rather than repeating it, so a caller must put
    /// it back — see `assembled(from:)`.
    public static let assistantPrefill = "**Current work**\n-"

    /// The finished profile: what the model returned, joined back onto the prefill it was
    /// continuing. Trims only trailing whitespace from the prefill's own line so a reply
    /// that starts with a space reads as one list item, not two.
    public static func assembled(from reply: String) -> String {
        let continuation = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !continuation.isEmpty else { return "" }
        // A model that ignored the prefill and restated the heading must not get it twice.
        if continuation.hasPrefix("**Current work**") { return continuation }
        return assistantPrefill + " " + continuation
    }

    public static func instruction(today: Date = Date()) -> String {
        "Today is \(dayString(today)). Rewrite the user profile as four labeled sections, "
            + "in this order, each item a short line ending with the date it was last "
            + "confirmed in parentheses:\n"
            + "**Current work** — only items confirmed within the last \(currentWorkWindowDays) days. "
            + "Anything older is NOT current: drop it, or move it to Past work as one short clause.\n"
            + "**Past work** — at most 5 items, oldest dropped first.\n"
            + "**Environment** — durable facts: machines, terminal/tmux sessions and what each is "
            + "for, tools, network topology. Keep these across rewrites unless contradicted.\n"
            + "**Preferences** — how they like to work and be talked to.\n"
            + "Keep under \(requestedCharacters) characters; prefer dropping stale detail over "
            + "exceeding the limit. Never invent dates: use the dates given, or omit one. "
            + "Output only the profile text."
    }

    /// The model's input. Every conversation and every observed section is
    /// dated, and the current profile comes first so the model rewrites rather
    /// than appends.
    public static func input(
        currentProfile: String,
        observed: [ObservedSection],
        conversations: [Conversation],
        perConversationCap: Int
    ) -> String {
        var text = "Current profile:\n" + (currentProfile.isEmpty ? "(none)" : currentProfile)
        for section in observed where !section.lines.isEmpty {
            text += "\n\n\(section.title):"
            for line in section.lines { text += "\n- \(line)" }
        }
        text += "\n\nRecent conversations:"
        for conversation in conversations {
            let body = conversation.content.count > perConversationCap
                ? "…" + String(conversation.content.suffix(perConversationCap))
                : conversation.content
            let stamp = conversation.date.map { " (\(dayString($0)))" } ?? ""
            text += "\n\n\(conversation.title)\(stamp)\n\(body)"
        }
        return text
    }

    /// Guards the wholesale replacement. Rejects a refusal, an echo of the
    /// "(none)" placeholder the input itself injects, and — for a candidate that
    /// does NOT carry the requested structure — a drastic shrink of a substantial
    /// profile. A candidate that does carry the structure (two or more of the
    /// section headings) may shrink freely: that is the model pruning, which is
    /// the whole point.
    public static func acceptable(_ candidate: String, replacing existing: String) -> Bool {
        guard candidate.count >= 40, !candidate.contains("(none)") else { return false }
        if isStructured(candidate) { return true }
        if existing.count > 200, candidate.count < existing.count * 3 / 10 { return false }
        return true
    }

    public static func isStructured(_ text: String) -> Bool {
        sectionHeadings.filter { text.contains($0) }.count >= 2
    }

    public static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
