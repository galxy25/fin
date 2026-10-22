// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// A mission question that is really "the session this goal is about isn't running".
///
/// Live on 2026-10-22: a heartbeat tick on the MacBook Neo listed every tmux session,
/// found no `data-anamoly-reporter-agent`, and asked the user about it instead of
/// concluding anything. That question then held the daemon paused for two weeks. Levi:
/// "fin should be able to see all the … sessions and know nothing is related to that"
/// — a session that isn't running is a blocker on the goal, not a decision only the
/// user can make. So a mission tick's `request_input` that names a missing session
/// marks the goal blocked (surfaced in the ledger, synced to the apps) and is never
/// sent. A question inside a conversation is left alone: the user is right there.
public enum MissingSessionQuestion {
    public struct Verdict: Equatable, Sendable {
        public let goalID: String
        public let session: String

        public var blockedOn: String {
            "tmux session \(session) is not running on this machine"
        }
    }

    /// The open goal a question is about and the session it names that isn't live —
    /// or nil when the question should go to the user as asked.
    ///
    /// Deliberately narrow, because a wrong verdict swallows a real question:
    ///   - the live list must be non-empty (no pane scan yet proves nothing);
    ///   - the question must talk about a session;
    ///   - the missing name must be session-shaped (has `-` or `_`) and must also
    ///     appear in a not-done goal, which is the goal that gets blocked.
    public static func verdict(
        question: String, ledger: LedgerDocument?, liveSessions: [String]
    ) -> Verdict? {
        guard let ledger, !liveSessions.isEmpty,
              question.range(of: "session", options: .caseInsensitive) != nil
        else { return nil }
        let live = Set(liveSessions.map { $0.lowercased() })
        let goalIDs = Set(ledger.goals.map { $0.id.lowercased() })
        let open = ledger.goals.filter { $0.state != .done }
        for name in sessionShapedNames(in: question) {
            let lower = name.lowercased()
            guard !live.contains(lower), !goalIDs.contains(lower) else { continue }
            if let goal = open.first(where: { mentions($0, lower) }) {
                return Verdict(goalID: goal.id, session: name)
            }
        }
        return nil
    }

    static func sessionShapedNames(in text: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var names: [String] = []
        for raw in text.components(separatedBy: allowed.inverted) {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            guard name.count >= 4, name.contains(where: { $0 == "-" || $0 == "_" }),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    static func mentions(_ goal: Goal, _ lowerName: String) -> Bool {
        let fields = [goal.title, goal.why ?? "", goal.nextAction ?? "", goal.blockedOn ?? ""] + goal.tags
        return fields.contains { $0.lowercased().contains(lowerName) }
    }
}
