// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// The real outcome of one `onNotify` push, reported honestly rather than collapsed to
/// "a channel exists". A runner awaits its actual send (bounded — see the runner's own
/// timeout) before answering, so the model never hears "sent" for a push that hasn't
/// gone out, and never hears "failed" for one that's simply still in flight.
public enum AgentNotifyOutcome: Equatable, Sendable {
    /// The channel confirmed the push went out.
    case delivered
    /// Handed off to a channel, but no confirmation arrived within the runner's bounded
    /// wait — most likely still in flight, not a known failure.
    case queued
    /// A channel IS configured and a send was attempted, but is confirmed NOT to have
    /// gone out (a non-2xx/transport error a confirming channel reported, or the only
    /// configured channel failing to even launch). Distinct from `unavailable` (no
    /// channel exists at all) — an operator debugging silence needs to know which one
    /// it is, and a definite failure from a channel that CAN confirm must never be
    /// papered over by another channel that merely launched without confirming anything
    /// (see `runNotifyCommand`'s own doc comment on what a launch does and doesn't prove).
    case failed
    /// No push channel is configured at all.
    case unavailable
}

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
    /// reasoning, toolCall, toolResult, notice, error, turnStarted, turnProgress.
    public var kind: String
    public var text: String
    public var toolName: String?
    public var toolArguments: String?
    public var isFailure: Bool
    /// Which model-call attempt (1-based) this event corresponds to, and how many
    /// retries that took (`attempt - 1`) — both default to a fresh turn's 1/0 and are
    /// only ever set to something else by `AgentTurnEngine`, which tracks its own
    /// current attempt/retry count across a round trip and stamps every event with it
    /// (see `AgentTurnEngine.record`). Exists so the cloud mirror line's `attempt`/
    /// `retry_count` fields can report what actually happened instead of a hardcoded
    /// 1/0 for every line regardless of real retry activity.
    public var attempt: Int
    public var retryCount: Int

    public init(
        kind: String,
        text: String,
        toolName: String? = nil,
        toolArguments: String? = nil,
        isFailure: Bool = false,
        attempt: Int = 1,
        retryCount: Int = 0
    ) {
        self.timestamp = Date()
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.isFailure = isFailure
        self.attempt = attempt
        self.retryCount = retryCount
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
    // The engine advertises the full shared tool roster (`AgentToolSpec.all`), but several
    // of those tools act on state the engine doesn't own — the runner's heartbeat loop, its
    // notification surface, its second SSH channel. The runner (fin-agentd) wires these; a
    // runner that leaves them nil gets an honest "unavailable" tool result instead of a lie.

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
    /// the model made. Async so the runner can actually AWAIT the send (bounded — see
    /// `AgentNotifyOutcome`) instead of reporting a channel's mere existence as delivery.
    /// Nil hook → the tool reports it's unavailable in this runtime, the same honesty as
    /// the headless memory tools.
    public var onNotify: ((_ title: String, _ body: String) async -> AgentNotifyOutcome)?
    /// Fired when the model calls `read_session`. `session` is a name the engine has
    /// ALREADY validated (`TmuxSessionRead.validate`) or nil for "list the sessions";
    /// `lines` is already clamped. The runner turns that into a fixed argv on a channel of
    /// its own — the model never contributes a command line — and answers with the text or
    /// an honest failure. Nil hook → the tool reports it is unavailable in this runtime,
    /// exactly like `onNotify`: the roster is shared with the app, and an advertised tool
    /// must never be answered with a lie or an "unknown tool".
    public var onReadSession: ((_ session: String?, _ lines: Int) async -> AgentReadSessionOutcome)?

    /// Fired when the model calls `send_session`. `session` has ALREADY been validated as
    /// an EXPLICIT "session:window" target (`TmuxSessionSend.validateTarget` — no bare
    /// names reach here, unlike `onReadSession`), and `text` has already been trimmed and
    /// length-checked. `awaitSeconds` is already clamped. The runner types the text, then
    /// Enter, on the same kind of fixed-argv channel `onReadSession` uses — real
    /// keystrokes into a pane this process does not otherwise control, which is why the
    /// target arrives pre-validated to exactly one shape instead of a name to resolve.
    /// Nil hook → the tool reports it is unavailable, exactly like `onReadSession`.
    public var onSendSession: (
        (_ session: String, _ text: String, _ awaitSeconds: Int) async -> AgentSendSessionOutcome
    )?

    /// The tmux guard (see `TmuxCommandGuard`). NOT an optional hook, on purpose: a nil
    /// hook reads as "allow", and a guard must never be disarmed by omission.
    /// `.unenforced` is the explicit, named opt-out for a host with no tmux server of its
    /// own — the app drives an arbitrary SSH session where tmux is optional and the user's
    /// own session is often literally named `main`. The daemon sets it from its
    /// `connectCommand` (`TmuxSendGuard.forHost`), where the fail-closed default lives: a
    /// connect command with no socket in it yields `.standard`, and every explicit socket
    /// is then refused.
    public var tmuxGuard: TmuxSendGuard = .unenforced

    // NOTHING IS TYPED INTO THE TERMINAL TO DECIDE A REFUSAL — deleted this round, and
    // worth a note where the code used to be. `guardForThisSend` re-probed the live shell
    // for `$TMUX` before any send the guard's cheap prefilter thought might be a tmux
    // command, so that a socket-less `tmux …` could be allowed when the shell was proven to
    // be inside Fin's own tmux server. Two things were wrong with it, and the second is why
    // it is gone rather than fixed:
    //
    //   1. The prefilter is a deliberate SUPERSET — it answers true for ANY input holding a
    //      quote or a backslash, because `tm"u"x` runs. As a guard prefilter that is free;
    //      as the trigger for a side effect it meant `git commit -m "wip"` and `print("hi")`
    //      typed `echo FIN_ENV_123456=$TMUX` + Return into the pane first. In a shell that
    //      ran it; in a REPL, a TUI or vim those bytes went into the program.
    //   2. The answer came back through the same PTY the model writes to, so the party
    //      being checked could answer the check (a `sed` filter left running in the pane
    //      forges any `$TMUX` it likes).
    //
    // `TmuxCommandGuard`'s R1 replaced the question: a tmux command on a private-socket
    // host must NAME its server, so where a socket-less one would have landed is no longer
    // something anybody has to find out. The daemon still probes `$TMUX` once at launch —
    // as a log line for the operator, never as a gate.

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

    /// The model-call attempt/retry count `record` stamps on every event — see
    /// `AgentAuditEvent.attempt`/`retryCount`. Reset to a fresh 1/0 at the top of
    /// `submit` (so a new turn never inherits the previous turn's last completion's
    /// numbers) and advanced by `completeWithRetries` at the start of each of its own
    /// attempts — meaning it holds whatever attempt most recently ran once
    /// `completeWithRetries` returns, whether that attempt succeeded or exhausted
    /// retries, and every `record` call for the rest of that round trip (the assistant
    /// message it produced, its reasoning, the tool results that follow it) carries
    /// that same, accurate count.
    private var currentAttempt = 1
    private var currentRetryCount = 0

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
            isFailure: isFailure,
            attempt: currentAttempt,
            retryCount: currentRetryCount
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
        // A fresh turn must never inherit the previous turn's last completion's
        // attempt/retry count — see `currentAttempt`'s doc comment.
        currentAttempt = 1
        currentRetryCount = 0

        transcript.append(AgentMessage(role: .user, text: trimmed))
        record("userMessage", trimmed)
        // Turn-visibility signal (item 6 of the message-delivery-reliability work): the
        // INSTANT the user message is recorded, before any tool call or LLM round trip —
        // the whole point is the app/supervisor sees "received" within seconds, not only
        // once a reply is ready. See `DaemonTranscriptUplink` for the immediate (not
        // batched) flush this specific kind gets on the daemon side.
        record("turnStarted", "[turn] started")

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
            // Set BEFORE the call, not after: a failed attempt's own "error" record
            // below (and, on success, every `record` call for the rest of this round
            // trip) must reflect the attempt that is actually running, not the one
            // that just finished.
            currentAttempt = attempt
            currentRetryCount = attempt - 1
            do {
                let completion = try await client.complete(
                    messages: transcript.wireMessages,
                    // The roster follows the hooks: a runner with no `onReadSession`
                    // (the app, a test harness) must not be told the tool exists, or the
                    // model spends a turn calling something that can only answer
                    // "unavailable here". The dispatch's honest error stays as a backstop.
                    tools: AgentToolSpec.roster(
                        readSession: onReadSession != nil, sendSession: onSendSession != nil
                    )
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
            return await executeNotify(
                title: call.argument("title") ?? "",
                body: call.argument("body") ?? "",
                rawArguments: call.arguments
            )

        case AgentToolSpec.readSession.name:
            return await executeReadSession(
                session: call.argument("session"),
                lines: call.argument("lines").flatMap(Int.init),
                rawArguments: call.arguments
            )

        case AgentToolSpec.sendSession.name:
            return await executeSendSession(
                session: call.argument("session"),
                text: call.argument("text"),
                awaitSeconds: call.argument("await_output_seconds").flatMap(Int.init),
                rawArguments: call.arguments
            )

        default:
            let message = "Error: unknown tool \"\(call.name)\". Available tools: "
                + AgentToolSpec.roster(readSession: onReadSession != nil, sendSession: onSendSession != nil)
                    .map(\.name).joined(separator: ", ") + "."
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
    /// and await the REAL outcome (bounded — see `AgentNotifyOutcome`) before answering,
    /// so a proactively-social push never becomes a false "sent" or a false "failed". A
    /// missing hook or an unconfigured channel is told plainly so the model can fall back
    /// to its reply text rather than believing a phantom owner heard it.
    private func executeNotify(title: String, body: String, rawArguments: String) async -> String {
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
        switch await onNotify(trimmedTitle, trimmedBody) {
        case .delivered:
            return "Sent to the owner."
        case .queued:
            return "Queued for the owner — delivery wasn't confirmed within a few seconds, "
                + "but it may still land. Say anything important in your reply text too."
        case .failed:
            return "Delivery failed — a push channel is configured but the send is confirmed "
                + "not to have gone out. Say anything important in your reply text instead."
        case .unavailable:
            return "No push channel is configured, so the owner was not reached — say anything "
                + "important in your reply text instead, and keep going."
        }
    }

    /// The model's `read_session` tool: validate the NAME, clamp the size, hand both to
    /// the runner's hook, frame what comes back.
    ///
    /// THE VALIDATION LIVES HERE, above every runner, and it is a whitelist that rejects
    /// rather than a sanitizer that rewrites. That is the whole security argument for this
    /// tool: a name that survives `TmuxSessionRead.validate` contains no character any
    /// shell treats as anything but a literal, so the fixed argv the runner builds around
    /// it has exactly one variable word and nothing to escape. A runner is expected to
    /// validate again — the daemon does — but a host that forgot could not be handed a
    /// hostile name from here.
    private func executeReadSession(
        session raw: String?,
        lines requested: Int?,
        rawArguments: String
    ) async -> String {
        let toolName = AgentToolSpec.readSession.name
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        if let trimmed, !trimmed.isEmpty {
            guard let validated = TmuxSessionRead.validate(name: trimmed) else {
                let message = TmuxSessionRead.rejectionMessage(for: trimmed)
                record("error", message, toolName: toolName,
                       toolArguments: rawArguments, isFailure: true)
                return message
            }
            name = validated
        }
        // WHAT THIS ANSWER MAY COST THE CONVERSATION, derived from the window rather than
        // from a constant. `TmuxSessionRead.maxResponseBytes` bounds the exec channel;
        // this bounds the transcript, and without it one capture evicted the entire
        // conversation (see the note on `TmuxSessionRead.fit`).
        let byteBudget = readSessionByteBudget
        let lines = min(
            TmuxSessionRead.clampLines(requested),
            TmuxSessionRead.linesFitting(bytes: byteBudget)
        )
        record(
            "toolCall",
            name.map { "read_session: \($0) (\(lines) lines)" } ?? "read_session: list sessions",
            toolName: toolName, toolArguments: rawArguments
        )
        guard let onReadSession else {
            let message = "Error: read_session is not available in this runtime — there is no way "
                + "to read another session from here. Use read_terminal for your own terminal, and "
                + "say plainly in your reply that you cannot see the others."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        switch await onReadSession(name, lines) {
        case .failed(let why):
            let message = "Error: read_session could not read "
                + (name.map { "session \"\($0)\"" } ?? "this machine's sessions") + ": \(why)"
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        case .text(let output, let resolutionNote):
            guard let name else {
                return TmuxSessionRead.frameListing(
                    TmuxSessionRead.fit(output, intoBytes: byteBudget).text
                )
            }
            let fitted = TmuxSessionRead.fit(
                TmuxSessionRead.trim(output, toLastLines: lines), intoBytes: byteBudget
            )
            let truncationNote = fitted.trimmed
                ? "Only the last \(byteBudget / 1024) KB of that capture is shown — it was "
                    + "larger than one tool result may occupy in this model's context window, "
                    + "so the oldest lines were dropped and the newest kept."
                : nil
            // Both may apply (an auto-resolved read that was ALSO too big to show whole);
            // both belong outside the fence, so both go in `frameCapture`'s `note:`, never
            // folded into `output` where a hostile pane could forge an identical line.
            let combinedNote = [resolutionNote, truncationNote].compactMap { $0 }
                .joined(separator: " ")
            return TmuxSessionRead.frameCapture(
                session: name,
                lines: lines,
                output: fitted.text,
                note: combinedNote.isEmpty ? nil : combinedNote
            )
        }
    }

    /// How many bytes ONE read_session result may add to the transcript: a quarter of the
    /// context budget, which at the transcript's own ~4-characters-per-token estimate is
    /// `contextBudget` characters. Everything about this number is a heuristic except the
    /// property that matters — it is derived from `configuration.contextWindowTokens`, so a
    /// small window cannot be handed a capture that evicts the conversation it belongs to.
    private var readSessionByteBudget: Int {
        max(2_000, min(TmuxSessionRead.maxResponseBytes, contextBudget))
    }

    /// The model's `send_session` tool: validate the TARGET (must be an explicit
    /// "session:window", not a bare name — see `TmuxSessionSend`'s design note for why
    /// this tool is deliberately stricter than `read_session`), validate and bound the
    /// text, clamp the wait, hand all three to the runner's hook, and frame whatever
    /// comes back exactly the way `read_session` frames a capture — the "after" text is
    /// still somebody else's pane content, still untrusted, and the runner has already
    /// redacted it the same way `read_session`'s does before this ever sees it.
    private func executeSendSession(
        session raw: String?,
        text rawText: String?,
        awaitSeconds requested: Int?,
        rawArguments: String
    ) async -> String {
        let toolName = AgentToolSpec.sendSession.name
        let trimmedTarget = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTarget.isEmpty else {
            let message = "Error: send_session requires a \"session\" target — an exact "
                + "\"session:window\", never omitted. Call read_session first to find one."
            record("error", message, toolName: toolName, toolArguments: rawArguments, isFailure: true)
            return message
        }
        guard let target = TmuxSessionSend.validateTarget(name: trimmedTarget) else {
            let message = TmuxSessionSend.targetRejectionMessage(for: trimmedTarget)
            record("error", message, toolName: toolName, toolArguments: rawArguments, isFailure: true)
            return message
        }
        guard let text = rawText.flatMap(TmuxSessionSend.validateText) else {
            let message = TmuxSessionSend.textRejectionMessage(for: rawText ?? "")
            record("error", message, toolName: toolName, toolArguments: rawArguments, isFailure: true)
            return message
        }
        let awaitSeconds = TmuxSessionSend.clampAwaitSeconds(requested)
        record(
            "toolCall",
            "send_session: \(target) (\(text.count) chars"
                + (awaitSeconds > 0 ? ", waiting up to \(awaitSeconds)s" : "") + ")",
            toolName: toolName, toolArguments: rawArguments
        )
        guard let onSendSession else {
            let message = "Error: send_session is not available in this runtime — there is no "
                + "way to type into another session from here. Say plainly in your reply that "
                + "you cannot reach it."
            record("error", message, toolName: toolName, toolArguments: rawArguments, isFailure: true)
            return message
        }
        switch await onSendSession(target, text, awaitSeconds) {
        case .failed(let why):
            let message = "Error: send_session could not send to \"\(target)\": \(why)"
            record("error", message, toolName: toolName, toolArguments: rawArguments, isFailure: true)
            return message
        case .sent(.notWaited):
            return "Sent to \(target)."
        case .sent(.allAttemptsFailed):
            // Distinct from `.notWaited` on purpose — a wait WAS requested and every
            // attempt to confirm it failed. The send itself is not in doubt; only the
            // observation of what followed is.
            return "Sent to \(target). Waited up to \(awaitSeconds)s afterward, but could not "
                + "read that session's screen to confirm what happened — the message may still "
                + "have gone through. Check with read_session."
        case .sent(.observed(let after)):
            let byteBudget = readSessionByteBudget
            let fitted = TmuxSessionRead.fit(after, intoBytes: byteBudget)
            let framed = TmuxSessionRead.frameCapture(
                session: target,
                lines: TmuxSessionRead.defaultLines,
                output: fitted.text,
                note: fitted.trimmed
                    ? "Only the last \(byteBudget / 1024) KB of what followed is shown — it was "
                        + "larger than one tool result may occupy in this model's context window."
                    : nil,
                readOnly: false
            )
            return "Sent to \(target). What that session showed afterward:\n\n\(framed)"
        }
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

        // THE TMUX GUARD, FIRST: stay on your own tmux server. This runs before the
        // destructive heuristic because it is the more specific violation and its refusal
        // is the more actionable one — it names the server and points at read_session
        // instead. Deliberately ahead of the connected-session check too, so a refusal is
        // deterministic whether or not the PTY happens to be up.
        //
        // JUDGED ON THE EXACT BYTES THAT GET TYPED. `typedBody` is what reaches the PTY
        // below, and the difference is not cosmetic: judging the raw argument meant a
        // trailing newline — which the forced pre-classification path appends to EVERY
        // command it extracts — made `"tmux ls \\\n"` not "end in a backslash", so the
        // half-typed-line refusal never fired while the terminal really was left at PS2
        // waiting for the next send. The guard normalizes the same way internally, so no
        // caller can get this wrong; passing it here keeps the invariant visible.
        //
        // AND JUDGED FROM THE BYTES ALONE: no probe of the live shell, nothing typed into
        // the pane to work out where a socket-less tmux would land (see the note above
        // `init`). The decision is pure, so it costs nothing and cannot be answered by the
        // terminal it is about.
        let typed = AgentTurnLogic.typedBody(input)
        if case .refuse(let message) = tmuxGuard.evaluate(typed) {
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }

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
        // arrive as a lone keypress event. Same fix as `AgentRuntime.executeSendInput` —
        // and, unlike the `isSessionConnected` pre-check above, this one is not a race:
        // both calls are awaited below for their REAL outcome before anything downstream
        // (including `awaitOutput`, which would otherwise wait out its full timeout for
        // output that a dropped write can never produce) trusts that the bytes landed.
        let bodySend = session.sendAgentInput(AgentTurnLogic.typedBody(input))
        try? await Task.sleep(for: .milliseconds(250))
        let returnSend = session.sendAgentInput("\r")
        let bodySent = await bodySend?.value ?? true
        let returnSent = await returnSend?.value ?? true
        guard bodySent, returnSent else {
            let reason = session.lastError.map { " (\($0))" } ?? ""
            let message = "Error: sending input to the terminal failed\(reason). The command may be "
                + "partially typed or not sent at all — verify with read_terminal before retrying, "
                + "rather than assuming it went through. NO HUMAN IS WATCHING THIS SESSION — do not "
                + "repeat the send blind; confirm the session is reconnected first."
            record("error", message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
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
