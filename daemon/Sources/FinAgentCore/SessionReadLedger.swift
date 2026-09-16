// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// What has already been read from another session DURING THE CURRENT TURN, so the
/// same pane is never captured twice for nothing.
///
/// Live failure this exists for (2026-09-16, thread `m-b3bf22ae`): asked what the
/// Claude Code sessions were working on, the model read `main:0.0`, read `main:1.0`,
/// then read both again — four captures of two panes, 35 seconds of the turn, and no
/// new information asked for. It was not harmless. The first read of `main:1.0`
/// caught a full account of the App Store submissions; between it and the second the
/// human cleared that pane, so the duplicate returned a bare banner, and THAT is what
/// the model answered from. A re-read cannot add information when nothing has been
/// typed anywhere since — it can only replace good evidence with newer emptiness, and
/// push the good evidence toward the context trimmer.
///
/// So the rule is: within one turn, a second read of a target Fin has not sent
/// anything to is served from the first read. `send_session` clears the whole ledger
/// (not just that target's entry) — once keystrokes land in a pane, any pane may have
/// changed, and the resolution from a bare name like "fin" to a real target is not
/// visible here anyway.
public struct SessionReadLedger {
    /// Key for the no-arguments listing call, which is equally pointless to repeat.
    static let listingKey = "\u{0}listing"

    private var captures: [String: String] = [:]

    public init() {}

    /// Start of a turn: nothing has been read yet.
    public mutating func reset() {
        captures = [:]
    }

    /// Keys are the name the MODEL asked for, not the pane it resolved to: that is what
    /// a duplicate call repeats, and it is the only identifier available before the read
    /// actually happens.
    static func key(for session: String?) -> String {
        guard let session, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return listingKey
        }
        return session.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public mutating func recordRead(session: String?, result: String) {
        captures[Self.key(for: session)] = result
    }

    /// Anything typed into any pane invalidates every capture.
    public mutating func recordSend() {
        captures = [:]
    }

    /// The result to serve instead of reading again, or nil to go and read.
    public func cached(session: String?) -> String? {
        captures[Self.key(for: session)]
    }

    /// The cached capture, wrapped so the model is told plainly why it is identical and
    /// what to do instead. The directive is the point: a weak model that re-read twice
    /// will re-read a third time unless the tool result itself ends the loop.
    public static func frameRepeat(session: String?, cached: String) -> String {
        let what = session.map { "\"\($0)\"" } ?? "the session listing"
        return "ALREADY READ THIS TURN. You read \(what) earlier in this same turn and nothing "
            + "has been typed into any session since, so its screen is the one you already have "
            + "— this is that exact capture, not a new one. Reading it again cannot show you "
            + "anything new. Do NOT call read_session for \(what) again in this turn: either "
            + "read a DIFFERENT pane you have not looked at yet, or answer the user now from "
            + "what you have already seen.\n\n\(cached)"
    }
}
