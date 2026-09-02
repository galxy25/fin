// FinAgentCore — canonical copy. This file is shared verbatim between the Fin app
// (compiled into the `fin` target via project.yml's extra sources path) and the
// headless fin-agentd daemon. Keep it free of UI, SwiftData, and app-only imports.
import Foundation

struct AgentToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    /// Raw JSON object string as emitted by the model. Parsed at execution time so a
    /// malformed payload surfaces as a tool error the model can correct, not a crash.
    let arguments: String
    /// Wall-clock execution time, including any await-for-output — set once the call has
    /// actually run, so the console can show what each call cost. Nil while pending.
    var durationMS: Int?

    /// Best-effort single string argument lookup.
    func argument(_ key: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let string = object[key] as? String { return string }
        if let number = object[key] as? NSNumber { return number.stringValue }
        return nil
    }
}

struct AgentMessage: Identifiable {
    enum Role: String {
        case system, user, assistant, tool
    }

    let id = UUID()
    var role: Role
    var text: String
    var toolCalls: [AgentToolCall] = []
    /// Set on `.tool` messages to tie a result back to the call that produced it.
    var toolCallID: String?
    /// Shown in the console but never sent to the model — transport errors, status
    /// notes, and anything else that is UI narration rather than conversation.
    var isLocalOnly: Bool = false
    /// A heartbeat-injected user turn: the model must see it, but the console renders
    /// it as a subtle status row rather than a full user bubble.
    var isHeartbeat: Bool = false
    /// For `.assistant` messages: how long the model took to produce this turn.
    var turnDurationMS: Int?
    /// When this message entered the conversation. Restored history carries its
    /// real recorded time (see `loadAgentHistory`), so the watchdog's staleness
    /// gate can tell an old restored conversation from live work.
    var timestamp: Date = Date()

    mutating func setToolCallDuration(_ durationMS: Int, forCallID callID: String) {
        guard let index = toolCalls.firstIndex(where: { $0.id == callID }) else { return }
        toolCalls[index].durationMS = durationMS
    }
}

/// Message history plus the context budgeting that keeps it inside the model's window.
///
/// The accounting is deliberately a heuristic (~4 characters per token) rather than a
/// real tokenizer: it only has to be conservative enough to keep requests from being
/// rejected, and every endpoint tokenizes differently anyway.
struct AgentTranscript {
    private(set) var messages: [AgentMessage] = []
    /// How many messages compaction has dropped so far, surfaced to the model in a
    /// single running note so it knows history was elided rather than never existing.
    private(set) var droppedMessageCount = 0

    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Per-message envelope overhead (role, delimiters) — small, but it compounds
    /// across a long transcript, and under-counting is what blows a request.
    private static let messageOverheadTokens = 4

    var estimatedTokenCount: Int {
        wireMessages.reduce(0) { total, message in
            var cost = Self.estimatedTokens(message.text) + Self.messageOverheadTokens
            for call in message.toolCalls {
                cost += Self.estimatedTokens(call.name) + Self.estimatedTokens(call.arguments)
            }
            return total + cost
        }
    }

    /// The subset actually sent to the model.
    var wireMessages: [AgentMessage] {
        messages.filter { !$0.isLocalOnly }
    }

    mutating func append(_ message: AgentMessage) {
        messages.append(message)
    }

    /// Stamps a tool call's execution time after it has run — the call is appended to the
    /// transcript when the model asks for it, which is before its cost is known.
    mutating func recordToolCallDuration(_ durationMS: Int, forCallID callID: String) {
        guard let index = messages.lastIndex(where: { message in
            message.toolCalls.contains { $0.id == callID }
        }) else { return }
        messages[index].setToolCallDuration(durationMS, forCallID: callID)
    }

    mutating func appendLocalNotice(_ text: String) {
        messages.append(AgentMessage(role: .system, text: text, isLocalOnly: true))
    }

    /// The provenance block `markdownExport` prints above the conversation. A small
    /// config struct rather than the app's SwiftData `Agent` model, so the export stays
    /// available to the headless daemon; the app builds one from its `Agent` in
    /// `fin/Agent/AgentTranscriptExport.swift`.
    struct ExportContext {
        var agentName: String = ""
        var serverName: String = ""
        /// e.g. "Fin 1.0.0 (12)" or "fin-agentd".
        var producedBy: String = ""
        var providerLabel: String = ""
        /// Nil for providers with no endpoint (Apple on-device).
        var endpointURL: String?
        var modelIdentifier: String?
        var contextWindowTokens: Int = 0
        var maxOutputTokens: Int = 0
        var temperature: Double = 0
        var terminalContextLines: Int = 0
    }

    /// Human-readable rendering of the conversation for sharing or pasting into an issue.
    /// Local notices are included — "trimmed older turns", errors — because leaving them
    /// out makes gaps in the exported conversation inexplicable.
    /// Debug-fidelity export: everything both ends of the pipe saw. Tool calls carry
    /// their raw argument JSON verbatim (what actually went over the wire — the parsed
    /// "input" alone once hid an argument-encoding bug), plus per-call and per-turn
    /// timings, the system prompt, and the agent's model settings, since debugging an
    /// endpoint's behavior (an LM Studio server log, say) is impossible without knowing
    /// what it was told and how it was configured. The endpoint's API key is the one
    /// thing deliberately absent — it lives in the Keychain and stays there.
    func markdownExport(context: ExportContext) -> String {
        var lines: [String] = [
            "# \(context.agentName.isEmpty ? "Agent" : context.agentName) transcript",
            "",
            "- Session: \(context.serverName.isEmpty ? "—" : context.serverName)",
            "- Exported: \(ISO8601DateFormatter().string(from: Date()))",
            "- App: \(context.producedBy)",
            "- Provider: \(context.providerLabel)",
        ]
        if let endpointURL = context.endpointURL {
            lines.append("- Endpoint: \(endpointURL.isEmpty ? "—" : endpointURL)")
            lines.append("- Model: \(context.modelIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "—")")
        }
        lines.append("- Context window: \(context.contextWindowTokens) tokens · max output: \(context.maxOutputTokens) · temperature: \(context.temperature)")
        lines.append("- Terminal context: \(context.terminalContextLines) lines")
        lines.append("")

        for message in messages {
            switch message.role {
            case .system where !message.isLocalOnly:
                lines.append("### System prompt")
                lines.append("```")
                lines.append(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("```")
            case .system:
                lines.append("_\(message.text)_")
            case .user:
                lines.append("### You")
                lines.append(message.text)
            case .assistant:
                let duration = message.turnDurationMS.map { " (\($0)ms)" } ?? ""
                lines.append("### Agent\(duration)")
                if !message.text.isEmpty { lines.append(message.text) }
                for call in message.toolCalls {
                    let callDuration = call.durationMS.map { " (\($0)ms)" } ?? ""
                    lines.append("")
                    lines.append("**Tool call — `\(call.name)`\(callDuration)**")
                    lines.append("```json")
                    lines.append(call.arguments.trimmingCharacters(in: .whitespacesAndNewlines))
                    lines.append("```")
                }
            case .tool:
                lines.append("**Result**")
                lines.append("```")
                lines.append(message.text)
                lines.append("```")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    mutating func reset(systemPrompt: String) {
        messages = systemPrompt.isEmpty ? [] : [AgentMessage(role: .system, text: systemPrompt)]
        droppedMessageCount = 0
    }

    /// Drops the oldest exchanges until the transcript fits `budget`, preserving the
    /// leading system prompt. Returns true if anything was dropped.
    ///
    /// Tool results are only meaningful next to the assistant turn that requested them —
    /// most endpoints reject a `tool` message whose `tool_call_id` has no matching call
    /// still in the payload — so trimming always resumes at a non-`tool` message rather
    /// than slicing a call/result pair down the middle.
    @discardableResult
    mutating func compactIfNeeded(budget: Int) -> Bool {
        guard budget > 0, estimatedTokenCount > budget else { return false }

        // Anything before this index is preserved verbatim: the system prompt, plus the
        // compaction note itself once one exists.
        let preservedPrefix = messages.first?.role == .system && !(messages.first?.isLocalOnly ?? false) ? 1 : 0
        var dropped = 0

        while estimatedTokenCount > budget {
            var dropIndex = preservedPrefix
            // Skip past an existing compaction note so it is updated, never re-dropped.
            if dropIndex < messages.count, isCompactionNote(messages[dropIndex]) {
                dropIndex += 1
            }
            guard dropIndex < messages.count else { break }

            messages.remove(at: dropIndex)
            dropped += 1

            // Orphaned tool results left at the head would reference a call that is gone.
            while dropIndex < messages.count, messages[dropIndex].role == .tool {
                messages.remove(at: dropIndex)
                dropped += 1
            }

            // Nothing left worth trimming — the remaining messages are the live turn.
            if messages.count <= preservedPrefix + 1 { break }
        }

        guard dropped > 0 else { return false }
        droppedMessageCount += dropped
        updateCompactionNote(preservedPrefix: preservedPrefix)
        return true
    }

    private func isCompactionNote(_ message: AgentMessage) -> Bool {
        message.role == .system && message.text.hasPrefix(Self.compactionNotePrefix)
    }

    private static let compactionNotePrefix = "[context trimmed]"

    private mutating func updateCompactionNote(preservedPrefix: Int) {
        let text = "\(Self.compactionNotePrefix) \(droppedMessageCount) earlier message(s) were "
            + "dropped to stay inside the context window. Ask the user or re-read the terminal "
            + "if you need something from earlier."
        let note = AgentMessage(role: .system, text: text)

        if preservedPrefix < messages.count, isCompactionNote(messages[preservedPrefix]) {
            messages[preservedPrefix].text = text
        } else {
            messages.insert(note, at: min(preservedPrefix, messages.count))
        }
    }
}
