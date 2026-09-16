// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Token accounting for one model turn, as reported by the endpoint's `usage` block.
/// Authoritative where the transcript's own character-based estimate is only a guess,
/// so it is what gets recorded in the audit trail.
struct AgentUsage: Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
    }
}

/// Timing for one model turn.
///
/// Time-to-first-token and inter-token latency are only observable while the response is
/// still arriving, which is the reason this client streams: a single-shot request can
/// only ever report one round-trip number, and "the model took 9 seconds" hides whether
/// that was a slow prefill or slow decoding — the two have completely different fixes.
struct AgentTurnMetrics: Equatable {
    var totalMS: Int = 0
    /// Request start until the first content or tool-call fragment lands.
    var timeToFirstTokenMS: Int?
    /// Mean gap between successive streamed fragments after the first.
    var interTokenMeanMS: Double?
    /// Fragments received — an approximation of token count for endpoints that omit usage.
    var streamedChunks: Int = 0
    /// Span from the first to the last reasoning fragment, for models that stream thinking
    /// separately. Kept apart from `contentMS` because a reasoning model that spends most
    /// of a turn thinking looks identical, on total latency alone, to one that is simply slow.
    var reasoningMS: Int?
    /// Span from the first to the last visible-answer fragment.
    var contentMS: Int?
}

/// A model turn as returned by the endpoint.
struct AgentCompletion {
    var text: String
    var toolCalls: [AgentToolCall]
    /// Reasoning the model emitted before its answer, when the endpoint exposes it
    /// separately (Gemma 4 and other reasoning models do). Shown collapsed in the
    /// console and never fed back into the next request.
    var reasoning: String?
    var usage: AgentUsage = AgentUsage()
    var metrics: AgentTurnMetrics = AgentTurnMetrics()
}

enum AgentEndpointError: LocalizedError {
    case badURL(String)
    case transport(String)
    case http(status: Int, body: String)
    case malformedResponse(String)
    /// The response began `200 OK` and then failed PART WAY THROUGH THE STREAM.
    ///
    /// A hosted endpoint — OpenRouter especially, which answers as soon as some
    /// upstream provider accepts — reports rate limits, exhausted credit, provider
    /// outages, moderation and context overflow this way: inside the SSE body, as
    /// `{"error": {...}}` or a choice with `finish_reason: "error"`, long after the
    /// status line said everything was fine. Until this existed the accumulator read
    /// only `usage` and `delta`, so every one of those arrived as an EMPTY completion
    /// and was reported to the owner as "the model stopped without producing an
    /// answer" — the provider's own explanation discarded on the floor. `status`
    /// carries the provider's code when it gives one, so the retry rules can treat a
    /// mid-stream 429 exactly like a 429 in a status line.
    case streamFailure(status: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let url):
            return "\"\(url)\" isn't a valid endpoint URL."
        case .transport(let detail):
            return "Couldn't reach the endpoint: \(detail)"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : " — \(trimmed.prefix(400))"
            return "Endpoint returned HTTP \(status)\(detail)"
        case .malformedResponse(let detail):
            return "Couldn't read the endpoint's response: \(detail)"
        case .streamFailure(let status, let message):
            let code = status.map { " \($0)" } ?? ""
            return "The endpoint accepted the request and then failed mid-response"
                + "\(code.isEmpty ? "" : " (provider error\(code))") — \(message.prefix(400))"
        }
    }

    /// The provider's status code, wherever it arrived — a status line or a stream
    /// frame. One accessor so the retry rules never have to care which.
    var statusCode: Int? {
        switch self {
        case .http(let status, _): return status
        case .streamFailure(let status, _): return status
        default: return nil
        }
    }
}

/// Minimal OpenAI-dialect chat-completions client.
///
/// Non-streaming on purpose: with `stream: true` an endpoint splits `tool_calls`
/// across deltas keyed by index, with `function.arguments` arriving in fragments that
/// have to be concatenated before they parse — and several servers only fixed
/// `finish_reason` on the terminal chunk recently. A tool-driven loop gains little
/// from token-by-token rendering and loses a lot of reliability, so every turn here is
/// a single request/response.
/// A narrow, PUBLIC entry point for callers outside this module that need one raw,
/// tool-free completion — no transcript, no turn loop, no tool-calling roster. Exists
/// because `AgentEndpointClient`/`AgentMessage` stay internal on purpose (the app sees
/// them only because `project.yml` compiles this file's source directly into its own
/// module; `fin-agentd` genuinely imports `FinAgentCore` as a separate library and
/// can't reach internal types across that boundary) — `fin-agentd`'s memory
/// consolidator (`DaemonMemoryConsolidator`) is the first cross-module caller, and
/// widening the whole client's surface for one call site isn't worth it. Callers
/// WITHIN this module (e.g. `AgentTurnEngine`) should keep using `AgentEndpointClient`
/// directly, not this wrapper.
public func rawCompletion(
    instruction: String,
    input: String,
    endpointURL: String,
    model: String,
    apiKey: String?,
    temperature: Double,
    maxOutputTokens: Int,
    /// An already-started assistant turn for the model to CONTINUE. The single most
    /// effective control over a reasoning model that will not stop deliberating: it is no
    /// longer deciding whether to begin. See `ProfileCompaction.assistantPrefill` for the
    /// measurements. The reply continues this text rather than repeating it, so the caller
    /// joins them back together.
    assistantPrefill: String? = nil
) async throws -> String {
    let client = AgentEndpointClient(
        baseURL: endpointURL, model: model, apiKey: apiKey,
        temperature: temperature, maxOutputTokens: maxOutputTokens
    )
    var messages = [
        AgentMessage(role: .system, text: instruction),
        AgentMessage(role: .user, text: input),
    ]
    if let assistantPrefill, !assistantPrefill.isEmpty {
        messages.append(AgentMessage(role: .assistant, text: assistantPrefill))
    }
    let completion = try await client.complete(messages: messages, tools: [])
    return completion.text
}

/// The one knob a host process sets on the (internal) endpoint client.
public enum AgentEndpointDefaults {
    public static func setRequestTimeout(seconds: Int) {
        AgentEndpointClient.defaultRequestTimeout = TimeInterval(min(max(seconds, 30), 1800))
    }

    public static var requestTimeoutSeconds: Int { Int(AgentEndpointClient.defaultRequestTimeout) }
}

struct AgentEndpointClient {
    let baseURL: String
    let model: String
    let apiKey: String?
    let temperature: Double
    let maxOutputTokens: Int
    /// How long one completion may take. Defaults to `defaultRequestTimeout`,
    /// which the daemon raises from its config: a 12B local model chewing an
    /// 8k context on a 32 GB Mac that is also archiving four TestFlight builds
    /// took longer than 120 s on 2026-09-12, and the user's question came back
    /// as "Fin couldn't finish: the request timed out".
    var requestTimeout: TimeInterval = AgentEndpointClient.defaultRequestTimeout

    /// Process-wide default, set once at startup (the daemon reads
    /// `agent.requestTimeoutSeconds` through `AgentEndpointDefaults`); the app
    /// keeps the historical 120 s.
    nonisolated(unsafe) static var defaultRequestTimeout: TimeInterval = 120

    private var completionsURL: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        // Accept a base ("…/v1") or a full path ("…/v1/chat/completions") so a pasted
        // URL from either the docs or another client works without editing.
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: trimmed + "/chat/completions")
    }

    func complete(
        messages: [AgentMessage],
        tools: [AgentToolSpec]
    ) async throws -> AgentCompletion {
        do {
            return try await send(messages: messages, tools: tools, requestUsage: true)
        } catch AgentEndpointError.http(let status, let body) where status == 400 {
            // `stream_options` is a newer addition to the dialect and stricter servers
            // reject the whole request rather than ignoring the unknown key. Losing token
            // counts is much better than losing the turn, so retry without it once.
            guard body.localizedCaseInsensitiveContains("stream_options") else {
                throw AgentEndpointError.http(status: status, body: body)
            }
            return try await send(messages: messages, tools: tools, requestUsage: false)
        }
    }

    private func send(
        messages: [AgentMessage],
        tools: [AgentToolSpec],
        requestUsage: Bool
    ) async throws -> AgentCompletion {
        guard let url = completionsURL else { throw AgentEndpointError.badURL(baseURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = requestTimeout

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(Self.wireMessage),
            "temperature": temperature,
            "max_tokens": maxOutputTokens,
            "stream": true,
        ]
        if requestUsage {
            // Asks the server to append a final usage-bearing chunk.
            payload["stream_options"] = ["include_usage": true]
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map(\.wireValue)
            // Only the string forms are portable — the OpenAI object form of
            // `tool_choice` is rejected outright by LM Studio.
            payload["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let startedAt = Date()
        var accumulator = StreamAccumulator(startedAt: startedAt)

        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no `URLSession.bytes(for:)` / `AsyncBytes` —
        // on Linux the whole SSE body is buffered with `data(for:)` and fed to the
        // same accumulator line by line. Chunk-level latency metrics degrade (every
        // "chunk" lands at once), but the parse and the result are identical.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AgentEndpointError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentEndpointError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let body = String(decoding: data, as: UTF8.self)
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            // SSE line endings may be \r\n; `bytes.lines` strips the \r on Darwin,
            // so strip it here too before the accumulator sees the line.
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if accumulator.consume(line: line) { break }
        }
        #else
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AgentEndpointError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            var text = String(data: body, encoding: .utf8) ?? ""
            // The server's own answer to "when should I come back?", which the backoff
            // would otherwise replace with a 400ms guess. Folded into the body rather
            // than added to the case so every existing `.http` construction still
            // compiles and every reader still sees one string.
            if let after = Self.retryAfterSeconds(http) {
                text = "[retry-after: \(after)s] " + text
            }
            throw AgentEndpointError.http(status: http.statusCode, body: text)
        }

        do {
            for try await line in bytes.lines {
                if accumulator.consume(line: line) { break }
            }
        } catch {
            throw AgentEndpointError.transport(error.localizedDescription)
        }
        #endif

        // A server that ignored `stream: true` answers with one plain JSON body and no
        // `data:` framing — parse it the non-streaming way rather than returning nothing.
        if !accumulator.sawStreamFraming {
            guard let data = accumulator.rawBody.data(using: .utf8), !accumulator.rawBody.isEmpty else {
                throw AgentEndpointError.malformedResponse("empty response")
            }
            var completion = try Self.parseCompletion(data)
            completion.metrics.totalMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            return completion
        }

        // A FAILURE MID-STREAM IS A FAILED CALL, not a short answer. Thrown rather than
        // returned so it reaches the retry rules and the audit trail with the
        // provider's own message intact — the alternative, which is what used to
        // happen, is an empty completion the engine reports as "the model stopped
        // without producing an answer" while the real reason is discarded.
        if let failure = accumulator.failure { throw failure }

        return accumulator.finish()
    }

    /// Reassembles an SSE stream into a single completion while timing it.
    ///
    /// Streamed tool calls arrive fragmented: each delta carries an `index`, and
    /// `function.arguments` is split across chunks that only parse once concatenated in
    /// order — so calls are accumulated per index and materialized at the end.
    private struct StreamAccumulator {
        let startedAt: Date

        private(set) var sawStreamFraming = false
        private(set) var rawBody = ""
        /// Set when the stream reported a failure after its 200. Read by the caller,
        /// which throws it instead of returning a truncated completion.
        private(set) var failure: AgentEndpointError?

        private var text = ""
        private var reasoning = ""
        private var usage = AgentUsage()
        private var toolFragments: [Int: (id: String?, name: String, arguments: String)] = [:]

        private var fragmentTimestamps: [Date] = []
        private var firstReasoningAt: Date?
        private var lastReasoningAt: Date?
        private var firstContentAt: Date?
        private var lastContentAt: Date?

        init(startedAt: Date) {
            self.startedAt = startedAt
        }

        /// Returns true when the stream signalled completion.
        mutating func consume(line: String) -> Bool {
            guard line.hasPrefix("data:") else {
                // Retain anything unframed so a non-streaming reply can still be parsed.
                if !line.isEmpty { rawBody += line }
                return false
            }
            sawStreamFraming = true

            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return true }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }

            if let usageObject = object["usage"] as? [String: Any] {
                usage = AgentEndpointClient.parseUsage(usageObject)
            }

            // A FAILURE CAN ARRIVE AFTER `200 OK`. Read it before anything else in the
            // frame: an error frame may still carry a choices array, and a half-written
            // answer must not be returned as though it were a whole one.
            if let failure = AgentEndpointClient.streamFailure(in: object) {
                self.failure = failure
                return true
            }

            guard let choices = object["choices"] as? [[String: Any]],
                  let choice = choices.first
            else { return false }

            // `finish_reason: "error"` is the other shape of the same event, and it
            // rides on the choice rather than the root.
            if let reason = choice["finish_reason"] as? String,
               reason == "error" || reason == "content_filter" {
                self.failure = .streamFailure(
                    status: nil,
                    message: "the provider ended the response early (finish_reason: \(reason))"
                )
                return true
            }

            let delta = choice["delta"] as? [String: Any] ?? [:]
            let now = Date()

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                text += chunk
                note(now, isReasoning: false)
            }
            if let chunk = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String),
               !chunk.isEmpty {
                reasoning += chunk
                note(now, isReasoning: true)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls { absorbToolFragment(call, at: now) }
            }
            return false
        }

        private mutating func note(_ time: Date, isReasoning: Bool) {
            fragmentTimestamps.append(time)
            if isReasoning {
                if firstReasoningAt == nil { firstReasoningAt = time }
                lastReasoningAt = time
            } else {
                if firstContentAt == nil { firstContentAt = time }
                lastContentAt = time
            }
        }

        private mutating func absorbToolFragment(_ call: [String: Any], at time: Date) {
            let index = call["index"] as? Int ?? 0
            let function = call["function"] as? [String: Any] ?? [:]
            var entry = toolFragments[index] ?? (id: nil, name: "", arguments: "")

            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
            if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
            if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                entry.arguments += arguments
            }

            toolFragments[index] = entry
            note(time, isReasoning: false)
        }

        func finish() -> AgentCompletion {
            let toolCalls: [AgentToolCall] = toolFragments
                .sorted { $0.key < $1.key }
                .compactMap { index, entry in
                    guard !entry.name.isEmpty else { return nil }
                    return AgentToolCall(
                        id: entry.id ?? "call_\(index)_\(UUID().uuidString.prefix(8))",
                        name: entry.name,
                        arguments: entry.arguments.isEmpty ? "{}" : entry.arguments
                    )
                }

            let (visible, inlineReasoning) = AgentEndpointClient.splitReasoning(from: text)
            var resolvedCalls = toolCalls
            if resolvedCalls.isEmpty, let recovered = AgentEndpointClient.recoverToolCall(from: visible) {
                resolvedCalls = [recovered]
            }

            return AgentCompletion(
                text: visible,
                toolCalls: resolvedCalls,
                reasoning: reasoning.isEmpty ? inlineReasoning : reasoning,
                usage: usage,
                metrics: metrics()
            )
        }

        private func metrics() -> AgentTurnMetrics {
            var result = AgentTurnMetrics()
            result.totalMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            result.streamedChunks = fragmentTimestamps.count

            if let first = fragmentTimestamps.first {
                result.timeToFirstTokenMS = Int(first.timeIntervalSince(startedAt) * 1000)
            }
            if fragmentTimestamps.count > 1, let first = fragmentTimestamps.first,
               let last = fragmentTimestamps.last {
                let span = last.timeIntervalSince(first) * 1000
                result.interTokenMeanMS = span / Double(fragmentTimestamps.count - 1)
            }
            if let start = firstReasoningAt, let end = lastReasoningAt {
                result.reasoningMS = Int(end.timeIntervalSince(start) * 1000)
            }
            if let start = firstContentAt, let end = lastContentAt {
                result.contentMS = Int(end.timeIntervalSince(start) * 1000)
            }
            return result
        }
    }

    fileprivate static func parseUsage(_ object: [String: Any]) -> AgentUsage {
        AgentUsage(
            promptTokens: object["prompt_tokens"] as? Int,
            completionTokens: object["completion_tokens"] as? Int,
            totalTokens: object["total_tokens"] as? Int
        )
    }

    /// Lists the model identifiers an endpoint is currently serving. Used by the agent
    /// editor to turn "what exactly is this model called?" from guesswork into a picker.
    static func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") {
            trimmed.removeLast("/chat/completions".count)
        }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/models") else {
            throw AgentEndpointError.badURL(baseURL)
        }

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AgentEndpointError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentEndpointError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else {
            throw AgentEndpointError.malformedResponse("model list wasn't in the expected shape")
        }
        return entries.compactMap { $0["id"] as? String }.sorted()
    }

    private static func wireMessage(_ message: AgentMessage) -> [String: Any] {
        var wire: [String: Any] = ["role": message.role.rawValue]
        // A tool-call turn legitimately has no prose; some servers reject `null` content
        // but accept an empty string, which is the safer thing to send.
        wire["content"] = message.text
        if !message.toolCalls.isEmpty {
            wire["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ]
            }
        }
        if let toolCallID = message.toolCallID {
            wire["tool_call_id"] = toolCallID
        }
        return wire
    }

    /// Pulls a provider error out of one decoded SSE frame, in the shapes seen in the
    /// wild: `{"error": {"message", "code"}}`, `{"error": "some string"}`, and the
    /// OpenRouter variant that nests the upstream's own body under `metadata.raw`.
    /// Pure and internal so it can be tested against captured frames without a server.
    /// `Retry-After`, in seconds, as either a delta or an HTTP date. OpenRouter sets it
    /// around 60s on a rate limit; honoring it is the difference between waiting once
    /// and burning three attempts inside two seconds for nothing.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = Int(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The wait a failed attempt asked for, parsed back out of the error's text.
    static func retryAfterSeconds(inErrorBody body: String) -> Int? {
        guard let range = body.range(of: #"\[retry-after: ([0-9]{1,5})s\]"#, options: [.regularExpression]),
              let digits = body[range].range(of: #"[0-9]{1,5}"#, options: [.regularExpression]),
              let seconds = Int(body[digits])
        else { return nil }
        return seconds
    }

    static func streamFailure(in object: [String: Any]) -> AgentEndpointError? {
        guard let raw = object["error"] else { return nil }
        if let message = raw as? String {
            return .streamFailure(status: nil, message: message)
        }
        guard let error = raw as? [String: Any] else {
            return .streamFailure(status: nil, message: "\(raw)")
        }
        // `code` is an int on OpenRouter and a string on some OpenAI-dialect servers.
        let status = (error["code"] as? Int)
            ?? (error["code"] as? String).flatMap { Int($0) }
            ?? (error["status"] as? Int)
        var message = (error["message"] as? String) ?? "the provider reported an error"
        // The upstream provider's own words, when the aggregator passes them through.
        if let metadata = error["metadata"] as? [String: Any] {
            if let raw = metadata["raw"] as? String, !raw.isEmpty {
                message += " — \(raw)"
            } else if let provider = metadata["provider_name"] as? String, !provider.isEmpty {
                message += " (provider: \(provider))"
            }
        }
        return .streamFailure(status: status, message: message)
    }

    private static func parseCompletion(_ data: Data) throws -> AgentCompletion {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentEndpointError.malformedResponse("response wasn't JSON")
        }
        if let error = root["error"] {
            throw AgentEndpointError.malformedResponse(String(describing: error).prefix(400).description)
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            throw AgentEndpointError.malformedResponse("no choices returned")
        }
        let message = first["message"] as? [String: Any] ?? [:]

        let rawContent = message["content"] as? String ?? ""
        let reasoning = (message["reasoning"] as? String)
            ?? (message["reasoning_content"] as? String)

        var toolCalls: [AgentToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for (index, raw) in rawCalls.enumerated() {
                guard let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                // `arguments` is a JSON-encoded *string* per the OpenAI dialect, but a
                // few servers inline an object instead — accept both.
                let arguments: String
                if let string = function["arguments"] as? String {
                    arguments = string
                } else if let object = function["arguments"],
                          let encoded = try? JSONSerialization.data(withJSONObject: object),
                          let string = String(data: encoded, encoding: .utf8) {
                    arguments = string
                } else {
                    arguments = "{}"
                }
                let id = raw["id"] as? String ?? "call_\(index)_\(UUID().uuidString.prefix(8))"
                toolCalls.append(AgentToolCall(id: id, name: name, arguments: arguments))
            }
        }

        let (visibleText, inlineReasoning) = splitReasoning(from: rawContent)

        // Fallback for endpoints or templates that drop the `tools` parameter and answer
        // in prose instead: a well-formed action object in the text is honored as a call.
        if toolCalls.isEmpty, let recovered = recoverToolCall(from: visibleText) {
            toolCalls = [recovered]
        }

        return AgentCompletion(
            text: visibleText,
            toolCalls: toolCalls,
            reasoning: reasoning ?? inlineReasoning,
            usage: (root["usage"] as? [String: Any]).map(parseUsage) ?? AgentUsage()
        )
    }

    /// Splits a reasoning preamble out of the visible answer. Gemma 4 emits thinking in a
    /// `<|channel|>thought … <|message|>` span, and several other local templates use
    /// `<think>…</think>`; either would otherwise be read as the model's actual reply.
    private static func splitReasoning(from content: String) -> (visible: String, reasoning: String?) {
        var text = content

        if let range = text.range(of: "<think>"),
           let end = text.range(of: "</think>", range: range.upperBound..<text.endIndex) {
            let thought = String(text[range.upperBound..<end.lowerBound])
            text.removeSubrange(range.lowerBound..<end.upperBound)
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), thought.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let channel = text.range(of: "<|channel|>") {
            let tail = text[channel.upperBound...]
            if let messageMarker = tail.range(of: "<|message|>") {
                let thought = String(tail[tail.startIndex..<messageMarker.lowerBound])
                let visible = String(tail[messageMarker.upperBound...])
                return (
                    visible.trimmingCharacters(in: .whitespacesAndNewlines),
                    thought.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    /// Recognizes `{"tool": "send_input", "arguments": {…}}` (or `"name"`/`"input"`
    /// spellings) embedded in an otherwise prose reply.
    private static func recoverToolCall(from text: String) -> AgentToolCall? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let name = (object["tool"] as? String) ?? (object["name"] as? String),
              AgentToolSpec.knownToolNames.contains(name)
        else { return nil }

        let argumentsObject = (object["arguments"] as? [String: Any])
            ?? (object["parameters"] as? [String: Any])
            ?? object.filter { $0.key != "tool" && $0.key != "name" }

        let arguments = (try? JSONSerialization.data(withJSONObject: argumentsObject))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return AgentToolCall(id: "recovered_\(UUID().uuidString.prefix(8))", name: name, arguments: arguments)
    }
}
