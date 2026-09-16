// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// What the SERVER says its context window really is, learned from the one place that
/// always tells the truth: its own refusal.
///
/// Live failure this exists for (2026-09-16). `contextWindowTokens` in the daemon's
/// config said 32768. The model was loaded at 8192. Nothing reconciled the two, so:
///
/// - `contextBudget` (window - output - headroom) came out at 30208 tokens, four times
///   the real window, and the transcript was never trimmed when it mattered;
/// - `readSessionByteBudget` is derived from that budget, so ONE pane capture was
///   allowed to be larger than the entire window the server had;
/// - the turn then had no room left to generate, and came back with an empty completion
///   in seven seconds. Three live requests died as "The model stopped without producing
///   an answer", and the cause was invisible: the daemon reported a model that would not
///   answer, not a window it had misjudged by 4x.
///
/// An llama.cpp-backed server refuses an oversized request with the real number in the
/// body (`"request (9025 tokens) exceeds the available context size (8192 tokens)"`,
/// `n_ctx`). That refusal is the ground truth, it costs nothing to read, and it is
/// protocol-shaped rather than vendor-shaped — the same discipline as naming the
/// protocol and not the vendor in the endpoint labels.
public enum ContextWindowProbe {
    /// The server's real window, parsed out of a refusal body. Nil when the body is not
    /// a context-size refusal — every other 400 must keep its own meaning.
    public static func windowTokens(fromRefusal body: String) -> Int? {
        guard body.localizedCaseInsensitiveContains("context size")
            || body.contains("n_ctx")
            || body.localizedCaseInsensitiveContains("exceed_context_size")
        else { return nil }

        // `"n_ctx":8192` is the structured field; the prose form is the fallback.
        for pattern in [#""n_ctx"\s*:\s*([0-9]{3,7})"#,
                        #"available context size \(([0-9]{3,7}) tokens\)"#,
                        #"context size is ([0-9]{3,7})"#] {
            if let range = body.range(of: pattern, options: [.regularExpression]),
               let digits = body[range].range(of: #"([0-9]{3,7})(?!.*[0-9])"#, options: [.regularExpression]),
               let value = Int(body[digits]), value > 0 {
                return value
            }
        }
        return nil
    }

    /// Whether a configured window is credible against what the server just reported.
    /// Deliberately not an equality check: a server may legitimately hold more than the
    /// agent chooses to use. Only claiming MORE than the server has is the bug.
    public static func isOverstated(configured: Int, serverWindow: Int) -> Bool {
        configured > serverWindow
    }

    /// The operator-facing sentence for a mismatch. It names both numbers and the fix,
    /// because the symptom ("the model stopped without producing an answer") points
    /// nowhere near the cause.
    public static func mismatchMessage(configured: Int, serverWindow: Int) -> String {
        "Context window mismatch: this agent is configured for \(configured) tokens but the "
            + "endpoint's loaded model holds only \(serverWindow). Budgets derived from the "
            + "configured number — including how much of a session capture one tool result "
            + "may carry — are too large for the real window, which shows up as empty "
            + "completions rather than as an error. Clamping to \(serverWindow) for this "
            + "process; load the model with a larger context, or lower contextWindowTokens "
            + "to match, to fix it permanently."
    }
}
