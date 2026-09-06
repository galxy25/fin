// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// Model + sampling configuration for a headless engine. The daemon reads this straight
/// from its JSON config; the fields mirror the app's `Agent` model minus everything
/// UI-facing (name, default mode, notification prefs).
public struct AgentEngineConfiguration {
    public var endpointURL: String
    public var modelIdentifier: String
    public var apiKey: String?
    public var contextWindowTokens: Int
    public var maxOutputTokens: Int
    public var temperature: Double
    public var systemPrompt: String
    public var terminalContextLines: Int

    public init(
        endpointURL: String,
        modelIdentifier: String,
        apiKey: String? = nil,
        contextWindowTokens: Int = 8192,
        maxOutputTokens: Int = 640,
        temperature: Double = 0.2,
        systemPrompt: String = "",
        terminalContextLines: Int = 160
    ) {
        self.endpointURL = endpointURL
        self.modelIdentifier = modelIdentifier
        self.apiKey = apiKey
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.terminalContextLines = terminalContextLines
    }
}

/// One audit-trail line from the engine, shaped for JSONL. Deliberately simpler than the
/// app's SwiftData-backed `AgentLogEntry`: the daemon appends these to a flat file, and a
/// future server-side runner can map them into whatever store it owns.
public struct AgentAuditEvent: Codable, Sendable {
    public var timestamp: Date
    /// Mirrors the app's `AgentLogKind` raw values: userMessage, assistantMessage,
    /// reasoning, toolCall, toolResult, notice, error.
    public var kind: String
    public var text: String
    public var toolName: String?
    public var toolArguments: String?
    public var isFailure: Bool

    public init(
        kind: String,
        text: String,
        toolName: String? = nil,
        toolArguments: String? = nil,
        isFailure: Bool = false
    ) {
        self.timestamp = Date()
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.isFailure = isFailure
    }
}

/// How one submitted message ended.
public enum AgentTurnOutcome: Equatable, Sendable {
    /// The model produced a final prose answer.
    case answered(String)
    /// The turn failed (endpoint unreachable, model stopped answering, …).
    case failed(String)
    /// The model kept calling tools without converging and hit the round-trip ceiling.
    case toolBudgetExhausted
}

/// Headless reproduction of `AgentRuntime`'s endpoint loop: deterministic
/// pre-classification force path, tool execution including the awaited `send_input`,
/// retries with backoff, transcript compaction, and audit records via an injected sink.
///
/// AUTO-MODE ONLY, BY DESIGN: a daemon has no one to ask, so where the app would park a
/// destructive-looking command behind an approval sheet, this engine REFUSES it outright
/// and logs an error — the model is told plainly and asked to propose a safer approach.
/// There is deliberately no manual mode and no approval continuation here.
@MainActor
public final class AgentTurnEngine {
    private static let maxToolRoundTrips = 8
    private static let maxModelAttempts = 3

    /// Internal (not public) on purpose: `AgentTranscript` stays an internal shared type;
    /// the daemon observes the run through `AgentTurnOutcome` and the audit sink, and
    /// tests reach this via `@testable import`.
    private(set) var transcript = AgentTranscript()
    public private(set) var isBusy = false

    private let configuration: AgentEngineConfiguration
    private let session: any AgentSessionDriving
    private let audit: (AgentAuditEvent) -> Void

    // MARK: - Runner hooks
    //
    // The engine advertises the full shared tool roster (`AgentToolSpec.all`), but three
    // of those tools act on state the engine doesn't own — the runner's heartbeat loop
    // and its notification surface. The runner (fin-agentd) wires these; a runner that
    // leaves them nil gets an honest "unavailable" tool result instead of a lie.

    /// Fired when the model calls `request_input`; the runner surfaces the question
    /// (notify hook, push service, …). The tool result mirrors the app's acknowledgment.
    public var onRequestInput: ((String) -> Void)?
    /// Fired on `monitor` start. The argument is the model-requested interval already
    /// clamped to 15...600 seconds, or 0 for "keep the current interval". Returns the
    /// effective interval the runner will actually beat at.
    public var onMonitorStart: ((Int) -> Int)?
    /// Fired on `monitor` stop; the runner disables its heartbeat loop.
    public var onMonitorStop: (() -> Void)?
    /// Fired when the MODEL calls `notify` — the proactively-social push. The engine
    /// never calls this on its own (no heartbeat, no completion, no forced path routes
    /// here); it fires only from `executeNotify`, so a notification is always a choice
    /// the model made. Returns whether the runner has a live channel to carry it, so the
    /// tool can tell the model the truth. Nil hook → the tool reports it's unavailable in
    /// this runtime, the same honesty as the headless memory tools.
    public var onNotify: ((_ title: String, _ body: String) -> Bool)?

    public init(
        configuration: AgentEngineConfiguration,
        session: any AgentSessionDriving,
        audit: @escaping (AgentAuditEvent) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.session = session
        self.audit = audit
        transcript.reset(systemPrompt: configuration.systemPrompt)
    }

    /// Rough budget headroom for the tool schemas and the model's own reply, which are
    /// part of the window but never part of the transcript we measure.
    private var contextBudget: Int {
        max(512, configuration.contextWindowTokens - configuration.maxOutputTokens - 512)
    }

    private func record(
        _ kind: String,
        _ text: String,
        toolName: String? = nil,
        toolArguments: String? = nil,
        isFailure: Bool = false
    ) {
        guard !text.isEmpty else { return }
        audit(AgentAuditEvent(
            kind: kind,
            text: text,
            toolName: toolName,
            toolArguments: toolArguments,
            isFailure: isFailure
        ))
    }

    /// Runs one full exchange: user message in, tool round-trips as needed, final answer
    /// (or failure) out. Sequential by design — a second submit while busy is refused.
    public func submit(_ text: String) async -> AgentTurnOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Empty message.") }
        guard !isBusy else { return .failed("The engine is already running a turn.") }
        isBusy = true
        defer { isBusy = false }

        transcript.append(AgentMessage(role: .user, text: trimmed))
        record("userMessage", trimmed)

        // Deterministic pre-classification, exactly as the app does it: the two
        // unambiguous intents get their tool executed before the model is ever asked.
        let intent = AgentIntentClassifier.classify(trimmed)
        if let forced = await forceToolCallIfNeeded(intent) {
            transcript.append(AgentMessage(role: .assistant, text: "", toolCalls: [forced.call]))
            record(
                "assistantMessage",
                "(deterministic pre-classification forced \(forced.call.name) before the model was asked)",
                toolName: forced.call.name,
                toolArguments: forced.call.arguments
            )
            transcript.append(AgentMessage(role: .tool, text: forced.result, toolCallID: forced.call.id))
            record("toolResult", forced.result, toolName: forced.call.name)
        }

        return await runEndpointLoop()
    }

    private func forceToolCallIfNeeded(
        _ intent: AgentIntentClassifier.Intent
    ) async -> (call: AgentToolCall, result: String)? {
        switch intent {
        case .ambiguous:
            return nil

        case .readTerminal:
            let result = await executeReadTerminal(lines: nil, rawArguments: "{}")
            let call = AgentToolCall(
                id: "forced_\(UUID().uuidString.prefix(8))",
                name: AgentToolSpec.readTerminal.name,
                arguments: "{}"
            )
            return (call, result)

        case .sendInput(let command):
            let input = command.hasSuffix("\n") ? command : command + "\n"
            let encoded = (try? JSONSerialization.data(withJSONObject: ["input": input]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let result = await executeSendInput(
                input: input,
                awaitOutputSeconds: AgentTurnLogic.defaultAwaitOutputSeconds,
                rawArguments: encoded
            )
            let call = AgentToolCall(
                id: "forced_\(UUID().uuidString.prefix(8))",
                name: AgentToolSpec.sendInput.name,
                arguments: encoded
            )
            return (call, result)
        }
    }

    // MARK: - Endpoint loop

    private func runEndpointLoop() async -> AgentTurnOutcome {
        var consecutiveEmptyReplies = 0

        for _ in 0..<Self.maxToolRoundTrips {
            if Task.isCancelled { return .failed("Cancelled.") }

            if transcript.compactIfNeeded(budget: contextBudget) {
                transcript.appendLocalNotice("Trimmed older turns to fit the context window.")
                record("notice", "Trimmed older turns to fit the context window.")
            }

            let outcome = await completeWithRetries()
            guard let completion = outcome.completion else {
                let message = outcome.errorMessage ?? "The model call failed."
                transcript.appendLocalNotice(message)
                return .failed(message)
            }

            transcript.append(AgentMessage(
                role: .assistant,
                text: completion.text,
                toolCalls: completion.toolCalls
            ))
            record(
                "assistantMessage",
                completion.text.isEmpty ? "(tool call only)" : completion.text
            )
            if let reasoning = completion.reasoning, !reasoning.isEmpty {
                record("reasoning", reasoning)
            }

            if completion.toolCalls.isEmpty {
                let trimmedText = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedText.isEmpty else {
                    return .answered(trimmedText)
                }

                consecutiveEmptyReplies += 1
                guard consecutiveEmptyReplies < 2 else {
                    let message = "The model stopped without producing an answer."
                    transcript.appendLocalNotice(message)
                    record("error", message, isFailure: true)
                    return .failed(message)
                }
                transcript.append(AgentMessage(
                    role: .system,
                    text: "Your last reply was empty. Answer the user's question now: call a tool first if you need real data, then give a complete final answer."
                ))
                continue
            }
            consecutiveEmptyReplies = 0

            for call in completion.toolCalls {
                if Task.isCancelled { return .failed("Cancelled.") }
                let result = await execute(call)
                transcript.append(AgentMessage(role: .tool, text: result, toolCallID: call.id))
                record("toolResult", result, toolName: call.name)
            }
        }

        let message = "Stopped after \(Self.maxToolRoundTrips) tool calls without finishing."
        transcript.appendLocalNotice(message)
        record("notice", message)
        return .toolBudgetExhausted
    }

    private func completeWithRetries() async -> (completion: AgentCompletion?, errorMessage: String?) {
        let client = AgentEndpointClient(
            baseURL: configuration.endpointURL,
            model: configuration.modelIdentifier,
            apiKey: configuration.apiKey,
            temperature: configuration.temperature,
            maxOutputTokens: configuration.maxOutputTokens
        )
        var lastMessage: String?

        for attempt in 1...Self.maxModelAttempts {
            if Task.isCancelled { return (nil, nil) }
            do {
                let completion = try await client.complete(
                    messages: transcript.wireMessages,
                    tools: AgentToolSpec.all
                )
                return (completion, nil)
            } catch {
                if Task.isCancelled { return (nil, nil) }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastMessage = message

                let retryable = AgentTurnLogic.isRetryableEndpointError(error) && attempt < Self.maxModelAttempts
                record(
                    "error",
                    retryable ? "\(message) (attempt \(attempt), retrying)" : message,
                    isFailure: true
                )
                guard retryable else { break }
                // Plain exponential backoff: 400ms, then 800ms.
                try? await Task.sleep(for: .milliseconds(400 * (1 << (attempt - 1))))
            }
        }
        return (nil, lastMessage)
    }

    // MARK: - Tools

    /// Internal (not private) so dispatch-path tests can drive a single tool call
    /// without staging a full model round-trip.
    func execute(_ call: AgentToolCall) async -> String {
        switch call.name {
        case AgentToolSpec.readTerminal.name:
            return await executeReadTerminal(
                lines: call.argument("lines").flatMap(Int.init),
                rawArguments: call.arguments
            )

        case AgentToolSpec.sendInput.name:
            guard let input = call.argument("input"), !input.isEmpty else {
                let message = "Error: send_input requires a non-empty \"input\" argument."
                record("error", message, toolName: call.name,
                       toolArguments: call.arguments, isFailure: true)
                return message
            }
            return await executeSendInput(
                input: input,
                awaitOutputSeconds: call.argument("await_output_seconds").flatMap(Int.init)
                    ?? AgentTurnLogic.defaultAwaitOutputSeconds,
                rawArguments: call.arguments
            )

        case AgentToolSpec.remember.name, AgentToolSpec.recall.name:
            // The specs are advertised (AgentToolSpec.all is shared with the app), so an
            // unknown-tool error would be a lie about our own roster. There is no memory
            // store in headless mode — say so honestly and give the model a way forward.
            let message = "Memory tools are unavailable in headless mode; "
                + "note anything important in your reply text instead."
            record("toolCall", "\(call.name) (unavailable in headless mode)",
                   toolName: call.name, toolArguments: call.arguments)
            return message

        case AgentToolSpec.requestInput.name:
            return executeRequestInput(
                question: call.argument("question") ?? "",
                rawArguments: call.arguments
            )

        case AgentToolSpec.monitor.name:
            return executeMonitor(
                action: call.argument("action") ?? "",
                intervalSeconds: call.argument("interval_seconds").flatMap(Int.init) ?? 0,
                rawArguments: call.arguments
            )

        case AgentToolSpec.notify.name:
            return executeNotify(
                title: call.argument("title") ?? "",
                body: call.argument("body") ?? "",
                rawArguments: call.arguments
            )

        default:
            let message = "Error: unknown tool \"\(call.name)\". Available tools: "
                + AgentToolSpec.all.map(\.name).joined(separator: ", ") + "."
            record("error", message, toolName: call.name, isFailure: true)
            return message
        }
    }

    /// Mirrors the app's `executeRequestInput`: record the question, surface it to whoever
    /// is listening, and acknowledge — the answer arrives as whatever comes back through
    /// the runner's inbound channel (a supervision directive, for the daemon).
    private func executeRequestInput(question: String, rawArguments: String) -> String {
        let toolName = AgentToolSpec.requestInput.name
        guard !question.isEmpty else {
            let message = "Error: request_input requires a non-empty \"question\" argument."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        record(
            "toolCall", "request_input: \(question)",
            toolName: toolName, toolArguments: rawArguments
        )
        guard let onRequestInput else {
            let message = "Error: request_input is not available in this runner; "
                + "state your question in your reply text instead."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        onRequestInput(question)
        // The app's canned acknowledgment, verbatim — the model's mental model of the
        // tool must not depend on which runner is hosting it.
        return "The user has been notified. Their next message will answer your question."
    }

    /// Mirrors the app's `executeMonitor` clamp and replies; the actual heartbeat state
    /// lives in the runner, reached through the hooks.
    private func executeMonitor(action: String, intervalSeconds: Int, rawArguments: String) -> String {
        let toolName = AgentToolSpec.monitor.name
        switch action.lowercased() {
        case "start":
            guard let onMonitorStart else {
                let message = "Error: monitoring is not available in this runner."
                record("error", message, toolName: toolName,
                       toolArguments: rawArguments, isFailure: true)
                return message
            }
            // Same clamp as the app: floor 15 (a 1s cadence is a turn storm, not
            // supervision), ceiling 600; 0 means "keep the current interval".
            let requested = intervalSeconds > 0 ? min(max(intervalSeconds, 15), 600) : 0
            let effective = onMonitorStart(requested)
            record("toolCall", "monitor start (every \(effective)s)",
                   toolName: toolName, toolArguments: rawArguments)
            return "Monitoring armed: you will be woken every \(effective)s to "
                + "check the task and act. End a reply with TASK COMPLETE (or call monitor "
                + "with \"stop\") when the task is verified done."

        case "stop":
            guard let onMonitorStop else {
                let message = "Error: monitoring is not available in this runner."
                record("error", message, toolName: toolName,
                       toolArguments: rawArguments, isFailure: true)
                return message
            }
            record("toolCall", "monitor stop",
                   toolName: toolName, toolArguments: rawArguments)
            onMonitorStop()
            return "Monitoring disarmed."

        default:
            let message = "Error: monitor requires action \"start\" or \"stop\"."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
    }

    /// The model's `notify` tool: record the note, hand it to the runner's push channel,
    /// and report back honestly. Deliberately synchronous and cheap — a proactively-social
    /// push must never become a reason the mission stalls, so the runner fires-and-forgets
    /// the actual delivery; this returns the moment it's handed off. A missing hook or an
    /// unconfigured channel is told plainly so the model can fall back to its reply text
    /// rather than believing a phantom owner heard it.
    private func executeNotify(title: String, body: String, rawArguments: String) -> String {
        let toolName = AgentToolSpec.notify.name
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            let message = "Error: notify requires a non-empty \"body\" argument."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record(
            "toolCall",
            trimmedTitle.isEmpty ? "notify: \(trimmedBody)" : "notify: \(trimmedTitle) — \(trimmedBody)",
            toolName: toolName, toolArguments: rawArguments
        )
        guard let onNotify else {
            let message = "Error: notify is not available in this runtime; the owner can't be "
                + "pushed from here. Put anything important in your reply text instead."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        let delivered = onNotify(trimmedTitle, trimmedBody)
        return delivered
            ? "Sent to the owner."
            : "No push channel is configured, so the owner was not reached — say anything "
                + "important in your reply text instead, and keep going."
    }

    private func executeReadTerminal(lines requested: Int?, rawArguments: String) async -> String {
        let lines = min(max(requested ?? configuration.terminalContextLines, 1), 400)
        let snapshot = session.eventLog.recentText(maxLines: lines)
        record(
            "toolCall",
            "read_terminal (\(lines) lines)",
            toolName: AgentToolSpec.readTerminal.name,
            toolArguments: rawArguments
        )
        return AgentTurnLogic.frameTerminalResult(snapshot)
    }

    private func executeSendInput(
        input: String,
        awaitOutputSeconds: Int,
        rawArguments: String
    ) async -> String {
        let toolName = AgentToolSpec.sendInput.name

        // NO HUMAN IN THE LOOP: where the app's runtime would raise an approval sheet,
        // the daemon refuses destructive-looking commands outright. The refusal is fed
        // back to the model as the tool result, so it can propose a safer path, and
        // logged as an error so the audit trail shows exactly what was blocked.
        if DestructiveCommandHeuristic.isDestructive(input) {
            let message = "REFUSED: \"\(AgentTurnLogic.summarize(input))\" looks destructive, and this "
                + "agent is running unattended with no one to approve it. The command was NOT sent. "
                + "Do not retry it; propose a safer approach, or tell the user it needs their explicit "
                + "confirmation in an interactive session."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }

        if Task.isCancelled { return "Cancelled before sending." }

        // A disconnected session's write path silently drops bytes, so sending would
        // confirm delivery of something that never arrived.
        guard session.isSessionConnected else {
            let message = "Error: the terminal session is not connected. Nothing was sent. "
                + "The session needs to reconnect before commands can run."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }

        let baselineEventID = session.eventLog.events.last?.id
        let executedAt = Date()
        // The Return is sent as its own write, a beat after the text: a \r riding in the
        // same stdin burst as a multi-character chunk is treated by TUI input libraries
        // (Claude Code's included) as part of a paste — inserted, not submitted. The
        // app's live wrapper test showed exactly that failure; the pause makes the \r
        // arrive as a lone keypress event. Same fix as `AgentRuntime.executeSendInput`.
        session.sendAgentInput(AgentTurnLogic.typedBody(input))
        try? await Task.sleep(for: .milliseconds(250))
        session.sendAgentInput("\r")
        let outcome = await awaitOutput(
            seconds: awaitOutputSeconds,
            after: baselineEventID,
            sentAt: executedAt,
            input: input
        )

        record(
            "toolCall", input,
            toolName: toolName, toolArguments: rawArguments
        )
        return AgentTurnLogic.frameSendInputResult(
            AgentTurnLogic.summarize(input),
            response: outcome.response,
            connectionDropped: outcome.connectionDropped
        )
    }

    /// Waits for the terminal to answer what was just sent — same settle-window logic as
    /// the app's `AgentRuntime.awaitOutput`; see `AgentTurnLogic` for the constants'
    /// reasoning.
    private func awaitOutput(
        seconds: Int,
        after baselineEventID: UUID?,
        sentAt: Date,
        input: String
    ) async -> (response: String, connectionDropped: Bool) {
        let requested = seconds <= 0 ? AgentTurnLogic.defaultAwaitOutputSeconds : seconds
        let budget = min(requested, AgentTurnLogic.maxAwaitOutputSeconds)
        let deadline = sentAt.addingTimeInterval(TimeInterval(budget))
        var connectionDropped = false

        while Date() < deadline, !Task.isCancelled {
            guard session.isSessionConnected else {
                connectionDropped = true
                break
            }
            if let lastActivity = session.eventLog.lastOutputActivity,
               lastActivity > sentAt {
                let quiet = Date().timeIntervalSince(lastActivity)
                if quiet >= AgentTurnLogic.echoOnlySettleWindow { break }
                if quiet >= AgentTurnLogic.outputSettleWindow,
                   AgentTurnLogic.containsResponse(
                       session.eventLog.outputText(after: baselineEventID, orRecordedAfter: sentAt),
                       beyond: input
                   ) {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (
            session.eventLog.outputText(after: baselineEventID, orRecordedAfter: sentAt),
            connectionDropped
        )
    }
}
