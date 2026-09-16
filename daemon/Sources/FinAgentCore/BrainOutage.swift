// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// Failures of the BRAIN that no retry and no restart can fix.
///
/// The daemon's answer to five consecutive failed turns is to page the owner and
/// `exit(1)`. Under launchd `KeepAlive=true` that is a restart, which is the right
/// move for a wedged process or a model that fell over — the next launch probes the
/// brain, waits for it, and carries on.
///
/// It is the WRONG move for a revoked key, an exhausted balance, or a model the
/// account may not use. Those conditions are identical after a restart, so the daemon
/// restarts into the same wall forever, spending an attempt each time — and on a
/// metered endpoint, spending money to discover repeatedly that there is none. That
/// became a live possibility the moment a hosted provider could be the brain
/// (2026-09-16); against LM Studio on loopback there was no such class of failure.
///
/// So these are classified, not counted: one page, then suspend the beat loop and stay
/// up. Staying up matters — a suspended daemon still answers the control plane, still
/// reports its site, and still tells anyone who looks WHY it is not thinking, where an
/// exited one is just absent.
public enum BrainOutage: String, Sendable, Equatable {
    /// 401 / 403 — the key is wrong, revoked, or not entitled to this model.
    case credentials
    /// 402 — the account is out of credit.
    case payment

    /// The outage a provider status implies, or nil when a restart or a retry could
    /// plausibly help. Deliberately narrow: only codes whose meaning is "this exact
    /// request will fail identically until a human changes something".
    public static func forStatus(_ status: Int?) -> BrainOutage? {
        switch status {
        case 401, 403: return .credentials
        case 402: return .payment
        default: return nil
        }
    }

    /// Classified from an endpoint error, wherever the status arrived — a status line
    /// or, on a hosted endpoint, a frame inside a stream that already returned 200.
    public static func forError(_ error: Error) -> BrainOutage? {
        guard let endpointError = error as? AgentEndpointError else { return nil }
        return forStatus(endpointError.statusCode)
    }

    /// What the owner is told, once. Names the condition and the fix, because the
    /// symptom — an agent that has stopped answering — is the same for all of them.
    public var ownerMessage: String {
        switch self {
        case .credentials:
            return "Fin's brain rejected its credentials (HTTP 401/403). The agent is up but "
                + "not thinking. Check agent.apiKey — a trailing newline in the key is enough "
                + "to cause this — and that the key may use the configured model."
        case .payment:
            return "Fin's brain is out of credit (HTTP 402). The agent is up but not thinking. "
                + "Add credit, or point agent.endpointURL at a local model to keep working."
        }
    }

    /// The log line, which says plainly why the daemon is staying up instead of exiting.
    public var logLine: String {
        "[brain] \(rawValue) failure — no restart can fix this, so beats are suspended and "
            + "the process stays up to keep reporting. Fix the config and kickstart."
    }
}
