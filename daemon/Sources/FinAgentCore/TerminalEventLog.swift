// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation
#if canImport(Combine)
import Combine

/// SwiftUI-observable on Apple platforms; on Linux (where Combine does not exist and
/// nothing observes the log) the class stands alone.
public typealias TerminalEventLogObservable = ObservableObject
#else
public protocol TerminalEventLogObservable: AnyObject {}
#endif

/// One coalesced burst of terminal activity: either something typed (by the human, via the
/// accessory row, or by the agent) or something the remote sent back.
///
/// Chunking — not one entry per byte or per SSH packet — is what makes this readable. SSH
/// delivers output in small packet-sized bursts, and a human types one character at a time,
/// so grouping consecutive same-kind traffic that arrives within a short quiet window into a
/// single chunk is what turns a raw byte stream into something that reads like "the user ran
/// X, then saw Y" instead of hundreds of one-character fragments.
public struct TerminalEvent: Identifiable, Equatable {
    public enum Kind: String {
        case input
        case output
    }

    public let id = UUID()
    public let kind: Kind
    public let startedAt: Date
    public private(set) var endedAt: Date
    public private(set) var text: String

    /// One chunk never grows past this; a continuously streaming command (a big cat, a
    /// fast build) would otherwise coalesce into a single multi-megabyte event that every
    /// downstream render walks in full. The newest bytes are the ones worth keeping.
    fileprivate static let maxTextLength = 32_000

    fileprivate mutating func absorb(_ more: String, at time: Date) {
        text += more
        if text.count > Self.maxTextLength {
            text = "\u{2026}" + text.suffix(Self.maxTextLength)
        }
        endedAt = time
    }
}

/// Timestamped, chunked record of everything sent to and received from a terminal session,
/// kept independently of SwiftTerm's own buffer.
///
/// SwiftTerm's buffer answers "what does the screen look like right now" — a flattened grid
/// with no memory of when anything happened or which lines came from which command. This
/// answers a different question, "what happened, in order, and when" — which is what the
/// agent actually needs to reason about a session rather than parrot its current contents.
@MainActor
public final class TerminalEventLog: TerminalEventLogObservable {
    /// Consecutive same-kind traffic within this window is one chunk. Long enough that a
    /// multi-packet burst of `ls -la` output lands in one chunk; short enough that a
    /// genuine pause (the shell waiting on the next command) starts a new one.
    private static let chunkGap: TimeInterval = 0.35
    /// Bounds memory on a long-lived session; old chunks are simply the least useful context.
    private static let maxEvents = 500

    public init() {}

    #if canImport(Combine)
    @Published public private(set) var events: [TerminalEvent] = []
    #else
    public private(set) var events: [TerminalEvent] = []
    #endif

    public func recordInput(_ bytes: [UInt8]) { record(.input, bytes: bytes) }
    public func recordOutput(_ bytes: [UInt8]) { record(.output, bytes: bytes) }

    private func record(_ kind: TerminalEvent.Kind, bytes: [UInt8]) {
        guard let text = Self.decode(bytes), !text.isEmpty else { return }
        let now = Date()

        if !events.isEmpty, events[events.count - 1].kind == kind,
           now.timeIntervalSince(events[events.count - 1].endedAt) < Self.chunkGap {
            events[events.count - 1].absorb(text, at: now)
            return
        }

        events.append(TerminalEvent(kind: kind, startedAt: now, endedAt: now, text: text))
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }

    /// Renders the most recent chunks as labeled, timestamped text, newest content last.
    /// Stops at a whole-chunk boundary rather than truncating mid-chunk — a chunk cut in
    /// half is worse than one chunk fewer, since it reads as truncated mid-thought.
    public func recentText(maxLines: Int, maxCharacters: Int = 12_000) -> String {
        guard maxLines > 0, !events.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var included: [String] = []
        var lineBudget = maxLines

        for event in events.reversed() {
            let rendered = Self.render(event, using: formatter)
            let lineCount = rendered.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
            if !included.isEmpty, lineCount > lineBudget { break }
            included.append(rendered)
            lineBudget -= lineCount
            if lineBudget <= 0 { break }
        }

        var text = included.reversed().joined(separator: "\n")
        if text.count > maxCharacters {
            text = "\u{2026}\n" + text.suffix(maxCharacters)
        }
        return text
    }

    /// When the newest event is output, the moment it last grew — the signal `send_input`
    /// uses to decide the terminal has gone quiet after a command. Nil until any output.
    public var lastOutputActivity: Date? {
        events.last(where: { $0.kind == .output })?.endedAt
    }

    /// Everything the terminal printed after the given event, rendered like `recentText`.
    /// `nil` means "since the beginning". Input events are skipped — the caller sent the
    /// input; what it's asking for is the response.
    ///
    /// `orRecordedAfter` covers baseline eviction: on a long await, the 500-event cap can
    /// push the baseline event out of the array entirely, and falling back to "everything"
    /// would present pre-command scrollback as the command's response. A timestamp can't
    /// be evicted, so it bounds the fallback instead.
    public func outputText(after eventID: UUID?, orRecordedAfter fallback: Date? = nil, maxCharacters: Int = 6_000) -> String {
        var newer = events[...]
        if let eventID {
            if let index = events.lastIndex(where: { $0.id == eventID }) {
                newer = events[events.index(after: index)...]
            } else if let fallback {
                newer = events.drop(while: { $0.startedAt <= fallback })[...]
            }
        }
        let outputs = newer.filter { $0.kind == .output }
        guard !outputs.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var text = outputs.map { Self.render($0, using: formatter) }.joined(separator: "\n")
        if text.count > maxCharacters {
            text = "\u{2026}\n" + text.suffix(maxCharacters)
        }
        return text
    }

    private static func render(_ event: TerminalEvent, using formatter: DateFormatter) -> String {
        let marker = event.kind == .input ? ">" : "<"
        let time = formatter.string(from: event.startedAt)
        let body = event.text.trimmingCharacters(in: .newlines)
        return "[\(time)] \(marker) \(body)"
    }

    private static func decode(_ bytes: [UInt8]) -> String? {
        guard let raw = String(bytes: bytes, encoding: .utf8) else { return nil }
        return stripANSI(raw)
    }

    /// Strips CSI/OSC/other C1 escape sequences and carriage-return-only line rewrites,
    /// leaving plain text. Not a terminal emulator — a highly interactive TUI (vim, htop)
    /// will still render as noise here, same as it would on any plain-text log; the goal is
    /// making ordinary command output (ls, cat, git, build logs) read cleanly, which covers
    /// the overwhelming majority of what an agent needs to reason about.
    ///
    /// One exception is tracked deliberately: a well-behaved app (tmux's status bar is the
    /// common case) redraws a fixed screen row — window list, clock — by saving the real
    /// cursor position, jumping elsewhere to write, then restoring it. That write decodes to
    /// perfectly plain, readable text, but it was never scrollback — it's UI chrome repeated
    /// on a timer, and left in, it can flood a chunk and crowd out what actually happened.
    /// Everything between a save and its matching restore is dropped for that reason, not
    /// just the escapes around it.
    private static func stripANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var chars = text.makeIterator()
        var pending = chars.next()
        var suppressing = false

        while let char = pending {
            if char == "\u{1B}" {
                pending = chars.next()
                switch pending {
                case "[":  // CSI: ESC [ ... final-byte(0x40-0x7E)
                    pending = chars.next()
                    while let c = pending, !("\u{40}"..."\u{7E}").contains(c) {
                        pending = chars.next()
                    }
                    // CSI form of save/restore cursor (ESC [ s / ESC [ u) — same reasoning
                    // as the more common DECSC/DECRC form below.
                    if pending == "s" { suppressing = true }
                    if pending == "u" { suppressing = false }
                    pending = chars.next()
                case "]":  // OSC: ESC ] ... BEL or ST (ESC \)
                    pending = chars.next()
                    while let c = pending, c != "\u{07}" {
                        if c == "\u{1B}" {
                            pending = chars.next()
                            if pending == "\\" { pending = chars.next() }
                            break
                        }
                        pending = chars.next()
                    }
                    if pending == "\u{07}" { pending = chars.next() }
                case "7":  // DECSC: save cursor
                    suppressing = true
                    pending = chars.next()
                case "8":  // DECRC: restore cursor
                    suppressing = false
                    pending = chars.next()
                case "(", ")", "*", "+":
                    // Character-set designation (e.g. ESC ( B) is three bytes total, not
                    // two — drop the designator byte too, or it survives as literal text.
                    pending = chars.next()
                    pending = chars.next()
                default:
                    // Every other single-byte escape (keypad mode, index, etc.) — drop the
                    // one byte following ESC and move on.
                    pending = chars.next()
                }
            } else if char == "\r" {
                // Bare CR (progress bars, spinners) — drop it; the terminal-side redraw it
                // caused isn't meaningful in a scrollback-style log.
                pending = chars.next()
            } else if char == "\r\n" {
                // Swift treats CRLF as a single grapheme cluster, so it never matches the
                // bare-CR case above — normalize it to a plain newline rather than letting
                // the literal CR through unstripped.
                if !suppressing { result.append("\n") }
                pending = chars.next()
            } else {
                if !suppressing { result.append(char) }
                pending = chars.next()
            }
        }
        return result
    }
}
