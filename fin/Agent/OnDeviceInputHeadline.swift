import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The app's half of `InputHeadline`: the "what's needed" title for a local
/// needs-input banner, written by Apple's on-device model when this device has one
/// (Levi, 2026-10-22). No network, no endpoint config — and the same bounded wait
/// and deterministic fallback the daemon uses, so a missing or slow model only ever
/// costs the title.
enum OnDeviceInputHeadline {
    static func headline(for question: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *), AppleOnDeviceBackend.isAvailable {
            return await InputHeadline.generate(question: question, timeoutSeconds: 8) { question in
                let session = LanguageModelSession(instructions: InputHeadline.instruction)
                return try await session.respond(to: question).content
            }
        }
        #endif
        return InputHeadline.fallback(question: question)
    }
}
