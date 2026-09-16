// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// What the endpoint reports about the window the model is actually serving, and where
/// that number came from.
///
/// Provenance is part of the reading on purpose. "32768" means something different when
/// the server said so than when it is only what the config hoped for, and the whole
/// 2026-09-16 outage was a configured number being mistaken for an observed one. A trace
/// that records the value without its source would reproduce exactly that confusion.
public struct ContextWindowReading: Equatable, Sendable, Codable {
    public enum Source: String, Equatable, Sendable, Codable {
        /// `GET /api/v0/models` — the LM Studio dialect's model listing, the only one of
        /// the probed shapes that reports a loaded window. Authoritative.
        case modelsAPI = "models_api"
        /// Parsed out of an oversized request's refusal (`n_ctx`). Authoritative, but
        /// only ever learned by having already overrun the window once.
        case refusal
        /// Nothing reported anything; this is `contextWindowTokens` from the config and
        /// has not been checked against reality.
        case configured
    }

    /// The window the model is serving right now — what every budget must respect.
    public var loadedTokens: Int
    /// The largest window this model could be loaded with, when the server says. Worth
    /// recording because it is the difference between "ask for more" and "you are at the
    /// ceiling": gemma-4-12b-qat serves 32768 of a possible 262144.
    public var maxTokens: Int?
    public var source: Source

    public init(loadedTokens: Int, maxTokens: Int? = nil, source: Source) {
        self.loadedTokens = loadedTokens
        self.maxTokens = maxTokens
        self.source = source
    }

    /// One line for a trace: the numbers, where they came from, and the headroom that
    /// matters. Never more than a line — this is stamped per turn.
    public var summary: String {
        var text = "\(loadedTokens) tokens (\(source.rawValue)"
        if let maxTokens, maxTokens > loadedTokens {
            text += ", of \(maxTokens) available"
        }
        return text + ")"
    }
}

public extension ContextWindowReading {
    /// The per-round-trip trace line: what the prompt actually cost against the window
    /// that actually exists, plus what is left.
    ///
    /// HEADROOM IS THE POINT. A prompt of 5,930 tokens is unremarkable on its own and
    /// alarming against an 8,192 window with 2,048 reserved for output — and on
    /// 2026-09-16 nothing anywhere recorded the second number, so three turns returned
    /// empty completions and the traces showed only that the model "stopped without
    /// producing an answer". `outputReserve` is the caller's `maxOutputTokens`: the room
    /// the answer needs, which is the room a prompt is really competing for.
    func turnTelemetry(promptTokens: Int?, completionTokens: Int?, outputReserve: Int) -> String {
        var parts: [String] = []
        if let promptTokens {
            let percent = loadedTokens > 0 ? (promptTokens * 100) / loadedTokens : 0
            parts.append("prompt \(promptTokens)/\(loadedTokens) (\(percent)%)")
            let free = loadedTokens - promptTokens - outputReserve
            parts.append(free >= 0
                ? "room for the answer \(free)"
                : "OVER BUDGET by \(-free) — the answer has nowhere to go, expect an empty reply")
        } else {
            parts.append("window \(loadedTokens)")
        }
        if let completionTokens { parts.append("completion \(completionTokens)") }
        parts.append("window from \(source.rawValue)")
        return "[context] " + parts.joined(separator: " · ")
    }

    /// Whether this round trip left no usable room for an answer — the condition that
    /// produces an empty completion rather than an error.
    func isStarvedOfOutputRoom(promptTokens: Int?, outputReserve: Int) -> Bool {
        guard let promptTokens else { return false }
        return promptTokens + outputReserve > loadedTokens
    }
}

public extension ContextWindowProbe {
    /// The models listing in the LM Studio dialect, derived from the chat endpoint's own
    /// base URL. `/v1/models` — the OpenAI-standard listing every server implements —
    /// reports id, object and owner and nothing about the window, which is precisely why
    /// this mismatch was invisible to everything in the stack.
    static func modelsAPIURL(forBaseURL baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Strip the API version segment the chat endpoint carries, whatever it is.
        for suffix in ["/v1", "/api/v0"] where trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
            break
        }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/api/v0/models")
    }

    /// Pulls the reading for `model` out of a models-listing body.
    ///
    /// Matched against the LOADED entry for that model: the listing carries every model
    /// the server knows about, and an unloaded one reports no window at all. A server
    /// that does not speak this dialect answers with something that has no `data` array —
    /// or, as LM Studio does for an unknown path, HTTP 200 with an `{"error": …}` body,
    /// which is why this parses for what it needs rather than trusting a status code.
    static func reading(fromModelsListing body: Data, model: String) -> ContextWindowReading? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return nil }

        let wanted = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = entries.filter { entry in
            guard let id = entry["id"] as? String else { return false }
            return id.lowercased() == wanted
        }
        // Prefer the loaded instance; LM Studio can hold two of the same model at
        // different windows (a JIT reload beside a hand-loaded one), and only the loaded
        // one is serving requests.
        let entry = candidates.first { ($0["state"] as? String) == "loaded" } ?? candidates.first
        guard let entry, let loaded = entry["loaded_context_length"] as? Int, loaded > 0 else {
            return nil
        }
        return ContextWindowReading(
            loadedTokens: loaded,
            maxTokens: (entry["max_context_length"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            source: .modelsAPI
        )
    }
}

public extension ContextWindowProbe {
    /// Asks the endpoint what window it is actually serving. Best effort by design:
    /// nothing in the OpenAI dialect reports this, so a server that does not speak the
    /// models-listing extension simply returns nil and the caller keeps its configured
    /// number — labelled `.configured`, never dressed up as observed.
    ///
    /// Short timeout and swallowed errors on purpose: this is telemetry. It runs beside
    /// the real work and must never be the reason a turn fails or a startup hangs.
    static func probe(
        baseURL: String,
        model: String,
        apiKey: String? = nil,
        timeout: TimeInterval = 5
    ) async -> ContextWindowReading? {
        guard let url = modelsAPIURL(forBaseURL: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        // The status code is not the test: LM Studio answers an unknown path with HTTP
        // 200 and an `{"error": …}` body, so only a parse that finds what it needs counts.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        return reading(fromModelsListing: data, model: model)
    }
}
