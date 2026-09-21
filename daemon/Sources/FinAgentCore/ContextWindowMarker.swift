// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// The on-disk record that makes a learned `ContextWindowReading` survive a daemon
/// restart. Mirrors `AwaitingUserInputMarker`'s shape and reasoning: `contextWindow` on
/// `AgentTurnEngine` is a plain `var`, so every restart forgets a ceiling learned from a
/// real refusal and starts back at the configured number — the exact number the refusal
/// just proved wrong. On the 2026-09-16/20 pattern (a crash-restart-recover cycle every
/// ~90-100 minutes) that meant the daemon re-learned the same lesson, the hard way, every
/// cycle: every restart replayed the empty-completion turns the first learning was
/// supposed to prevent.
///
/// Keyed to `modelIdentifier` on purpose. A ceiling learned for one model must never be
/// applied to a different one loaded later — LM Studio can swap models under the same
/// endpoint URL, and a stale reading would silently reintroduce the overstatement bug in
/// the other direction (clamping a bigger model's window to a smaller model's ceiling).
public struct ContextWindowMarkerState: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var loadedTokens: Int
    public var maxTokens: Int?
    public var source: ContextWindowReading.Source
    public var since: Date

    public init(
        modelIdentifier: String, loadedTokens: Int, maxTokens: Int?,
        source: ContextWindowReading.Source, since: Date
    ) {
        self.modelIdentifier = modelIdentifier
        self.loadedTokens = loadedTokens
        self.maxTokens = maxTokens
        self.source = source
        self.since = since
    }

    public var reading: ContextWindowReading {
        ContextWindowReading(loadedTokens: loadedTokens, maxTokens: maxTokens, source: source)
    }
}

public enum ContextWindowMarker {
    /// Nil on a missing or corrupt file, OR when the marker was learned for a different
    /// model than `modelIdentifier` names now — the same "unreadable is unblocked"
    /// fallback the other markers use, extended with the model-identity check that is
    /// this marker's whole reason to exist.
    public static func state(at path: String, forModel modelIdentifier: String) -> ContextWindowReading? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(ContextWindowMarkerState.self, from: data),
              state.modelIdentifier == modelIdentifier
        else { return nil }
        return state.reading
    }

    /// Best-effort write — a failed write must not take the turn that learned this down,
    /// it only means the next restart re-learns it the same way this one just did.
    public static func write(
        _ reading: ContextWindowReading, modelIdentifier: String, at path: String, now: Date = Date()
    ) {
        let state = ContextWindowMarkerState(
            modelIdentifier: modelIdentifier, loadedTokens: reading.loadedTokens,
            maxTokens: reading.maxTokens, source: reading.source, since: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func clear(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
