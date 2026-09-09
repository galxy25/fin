import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why an on-device agent can't run right now, in the user's terms.
enum AppleOnDeviceAvailability: Equatable {
    case available
    case osTooOld
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    var message: String? {
        switch self {
        case .available:
            return nil
        case .osTooOld:
            return "Apple's on-device model needs a newer version of this OS. Update, or point this agent at a custom endpoint."
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence. Point this agent at a custom endpoint instead."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use the on-device model."
        case .modelNotReady:
            return "Apple's on-device model is still downloading. Try again shortly."
        }
    }
}

/// Runs an agent turn against Apple's on-device model.
///
/// The control flow is inverted relative to the endpoint path: Foundation Models owns the
/// tool loop, calling registered tools itself and continuing until the model produces a
/// final answer. So instead of driving a loop here, the tools are handed closures back
/// into the runtime — which is also what lets manual-mode approval work, since a tool's
/// `call` is async and can simply not return until the user decides.
enum AppleOnDeviceBackend {

    static var availability: AppleOnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .modelNotReady
            }
        }
        return .osTooOld
        #else
        return .osTooOld
        #endif
    }

    static var isAvailable: Bool { availability == .available }

    /// Detects the failure mode where a small model falls into a repetition loop and emits
    /// the same character forever (long runs of em dashes are the signature one). Surfacing
    /// this as an error beats pasting a wall of punctuation into the conversation as though
    /// it were an answer.
    static func looksDegenerate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }

        // A long unbroken run of one non-alphanumeric character.
        var runCharacter: Character?
        var runLength = 0
        for character in trimmed where !character.isWhitespace {
            if character == runCharacter {
                runLength += 1
                if runLength >= 24, !character.isLetter, !character.isNumber { return true }
            } else {
                runCharacter = character
                runLength = 1
            }
        }

        // Or one punctuation mark dominating the whole reply.
        let counts = Dictionary(trimmed.filter { !$0.isWhitespace }.map { ($0, 1) }, uniquingKeysWith: +)
        if let (character, count) = counts.max(by: { $0.value < $1.value }),
           !character.isLetter, !character.isNumber,
           Double(count) / Double(max(trimmed.count, 1)) > 0.4 {
            return true
        }
        return false
    }
}

#if canImport(FoundationModels)

/// Non-optional on purpose: an optional field in a guided-generation schema is one more
/// decision for a small model to get wrong, and "0 means use the default" is handled
/// app-side for free.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ReadTerminalArguments {
    @Guide(description: "How many trailing lines to return. Use 0 for the default.")
    var lines: Int
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct SendInputArguments {
    @Guide(description: "The literal command text to type. Return is pressed for you — no trailing newline needed.")
    var input: String
    @Guide(description: "Seconds to wait for the terminal's response. Returns as soon as output settles, so a generous value costs nothing. Use 0 for the default (5) for ordinary shell commands; 30-120 when asking another agent or a long-running program a question.")
    var awaitOutputSeconds: Int
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct ReadTerminalTool: Tool {
    typealias Arguments = ReadTerminalArguments
    typealias Output = String

    let name = AgentToolSpec.readTerminal.name
    let description = AgentToolSpec.readTerminal.description
    /// Bridges back into the runtime so reads are logged and bounded exactly as they are
    /// on the endpoint path.
    let perform: @Sendable (Int?) async -> String

    func call(arguments: ReadTerminalArguments) async throws -> String {
        await perform(arguments.lines > 0 ? arguments.lines : nil)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct SendInputTool: Tool {
    typealias Arguments = SendInputArguments
    typealias Output = String

    let name = AgentToolSpec.sendInput.name
    let description = AgentToolSpec.sendInput.description
    /// Returns only once the input has been authorized (possibly by a human), sent, and
    /// the terminal's response awaited. Nil wait means "use the runtime default".
    let perform: @Sendable (String, Int?) async -> String

    func call(arguments: SendInputArguments) async throws -> String {
        await perform(arguments.input, arguments.awaitOutputSeconds > 0 ? arguments.awaitOutputSeconds : nil)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct RememberArguments {
    @Guide(description: "Short label for the fact.")
    var title: String
    @Guide(description: "The fact itself, one or two sentences.")
    var content: String
    @Guide(description: "Comma-separated keywords. Empty for none.")
    var tags: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct RecallArguments {
    @Guide(description: "Words to search for. Empty for most recent.")
    var query: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct RememberTool: Tool {
    typealias Arguments = RememberArguments
    typealias Output = String

    let name = AgentToolSpec.remember.name
    let description = AgentToolSpec.remember.description
    /// Bridges back into the runtime so saves are logged exactly as on the endpoint path.
    let perform: @Sendable (String, String, String) async -> String

    func call(arguments: RememberArguments) async throws -> String {
        await perform(arguments.title, arguments.content, arguments.tags)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct RequestInputArguments {
    @Guide(description: "The question the user must answer, one or two sentences.")
    var question: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct RequestInputTool: Tool {
    typealias Arguments = RequestInputArguments
    typealias Output = String

    let name = AgentToolSpec.requestInput.name
    let description = AgentToolSpec.requestInput.description
    let perform: @Sendable (String) async -> String

    func call(arguments: RequestInputArguments) async throws -> String {
        await perform(arguments.question)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct MonitorArguments {
    @Guide(description: "\"start\" to arm monitoring, \"stop\" to disarm.")
    var action: String
    @Guide(description: "Seconds between checks when starting. 0 keeps the current setting.")
    var intervalSeconds: Int
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct MonitorTool: Tool {
    typealias Arguments = MonitorArguments
    typealias Output = String

    let name = AgentToolSpec.monitor.name
    let description = AgentToolSpec.monitor.description
    let perform: @Sendable (String, Int) async -> String

    func call(arguments: MonitorArguments) async throws -> String {
        await perform(arguments.action, arguments.intervalSeconds)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct RecallTool: Tool {
    typealias Arguments = RecallArguments
    typealias Output = String

    let name = AgentToolSpec.recall.name
    let description = AgentToolSpec.recall.description
    let perform: @Sendable (String) async -> String

    func call(arguments: RecallArguments) async throws -> String {
        await perform(arguments.query)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct NotifyArguments {
    @Guide(description: "Short headline for the notification, a few words.")
    var title: String
    @Guide(description: "The message to the owner, one or two sentences.")
    var body: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct NotifyTool: Tool {
    typealias Arguments = NotifyArguments
    typealias Output = String

    let name = AgentToolSpec.notify.name
    let description = AgentToolSpec.notify.description
    let perform: @Sendable (String, String) async -> String

    func call(arguments: NotifyArguments) async throws -> String {
        await perform(arguments.title, arguments.body)
    }
}

#endif
