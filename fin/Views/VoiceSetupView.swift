import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Which quick-trigger the setup screen should lead with — decided from the raw
/// hardware model identifier. Apps cannot install a multi-action Shortcut, assign
/// the Action Button, or set Back Tap, so this only steers which *instructions*
/// we show; being wrong is cheap because the alternative is always visible too.
enum TriggerHardware: Equatable {
    /// A physical Action Button (iPhone 15 Pro / Pro Max and every iPhone since).
    case actionButton
    /// An iPhone with no Action Button — Back Tap or a Home Screen tile instead.
    case backTap
    /// iPad / Mac / unrecognized — no Action Button and no Back Tap; a Home Screen
    /// (or menu-bar) tile is the trigger.
    case noHardwareButton

    /// Classifies a model identifier ("iPhone17,1", "iPad13,1", …). The Action
    /// Button shipped with the iPhone 15 Pro (model major **16**) and has been on
    /// every iPhone since, so "iPhone major >= 16" is the durable test — a
    /// forward-looking assumption stated out loud, and cheap to be wrong about
    /// because the Back Tap alternative is shown regardless. Pure, for tests.
    static func classify(machineIdentifier id: String) -> TriggerHardware {
        guard id.hasPrefix("iPhone") else { return .noHardwareButton }
        let numeric = id.dropFirst("iPhone".count) // e.g. "17,1"
        guard let majorString = numeric.split(separator: ",").first,
              let major = Int(majorString) else { return .backTap }
        return major >= 16 ? .actionButton : .backTap
    }

    /// The device's own identifier, read from the kernel (or the simulator's env).
    /// Side-effecting; the classification above is the testable half.
    static func current() -> TriggerHardware {
        #if targetEnvironment(simulator)
        let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let id = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #endif
        return classify(machineIdentifier: id)
    }
}

/// Distribution details for the prebuilt companion shortcut.
enum VoiceShortcut {
    /// iCloud share link to the prebuilt "Talk to Fin" shortcut
    /// (Dictate Text → Send Message to Fin). EMPTY on purpose: no code can mint
    /// this link — it's produced by the Shortcuts app (Share → Copy iCloud Link)
    /// against an Apple ID — and shipping an unsigned `.shortcut` file would force
    /// the user through the scary "Allow Untrusted Shortcuts" toggle. While this
    /// is empty the screen leads with the always-works manual build; paste a link
    /// here once the shortcut has been shared and the one-tap "Add" button lights
    /// up as the primary path (the design's recommended option (a)).
    static let importLink = ""
}

/// Voice-first Action Button setup. The honest core: there is no API to install a
/// multi-action Shortcut (Dictate Text → Send Message to Fin) or to bind the
/// Action Button — Apple keeps both in the user's hands. So this screen does the
/// two things an app CAN do — open the Shortcuts editor and (when a link exists)
/// the import sheet — and spells out the manual steps precisely, ending with the
/// one hand step no app can remove: assigning the shortcut in Settings.
struct VoiceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let hardware = TriggerHardware.current()
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Press a button, talk, and Fin gets it — no typing, no opening the app. This takes a two-step Shortcut: **Dictate Text** opens the mic, then **Send Message to Fin** delivers what you said.")
                        .font(.callout)
                } header: {
                    Label("Voice button", systemImage: "waveform.badge.mic")
                }

                if !VoiceShortcut.importLink.isEmpty {
                    Section {
                        Button {
                            if let url = URL(string: VoiceShortcut.importLink) { openURL(url) }
                        } label: {
                            Label("Add the Voice Button Shortcut", systemImage: "square.and.arrow.down")
                        }
                    } header: {
                        Text("One-tap setup")
                    } footer: {
                        Text("Opens Shortcuts with the two actions already wired up — just tap Add Shortcut.")
                    }
                }

                Section {
                    Button {
                        // shortcuts://create-shortcut opens a blank shortcut in the
                        // editor. There is no public URL scheme to prefill actions,
                        // so the steps below are done by hand once.
                        if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                    stepRow(1, "Add an action and search for **Dictate Text**.", copyable: "Dictate Text")
                    stepRow(2, "Add another action: **Send Message to Fin**.", copyable: "Send Message to Fin")
                    stepRow(3, "Tap the **Message** field and pick the **Dictated Text** variable.")
                    stepRow(4, "Name it **Talk to Fin** and tap Done.")
                } header: {
                    Text(VoiceShortcut.importLink.isEmpty ? "Build the shortcut" : "Or build it by hand")
                } footer: {
                    Text("Tap a name to copy it, then paste into the Shortcuts search box.")
                }

                assignSection

                Section {
                    Text("Dictation must be on: **Settings → General → Keyboard → Enable Dictation** (usually already on).")
                        .font(.footnote)
                } header: {
                    Text("One-time prerequisite")
                }

                Section {
                    Text("Assigning the shortcut to your \(triggerName) is the one step Fin can't do for you — Apple keeps that in Settings. Everything else is above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Voice Button")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The "assign it" instructions, branched on what the hardware actually has —
    /// the design's requirement that the screen detect rather than assume an
    /// Action Button. The non-leading trigger is still offered as an alternative.
    @ViewBuilder
    private var assignSection: some View {
        switch hardware {
        case .actionButton:
            Section {
                Text("**Settings → Action Button** → swipe to **Shortcut** → choose **Talk to Fin**.")
                Text("No Action Button on another device? Use **Back Tap**: Settings → Accessibility → Touch → Back Tap → Double Tap → Talk to Fin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Assign it to the Action Button")
            }
        case .backTap:
            Section {
                Text("This iPhone has no Action Button. Use **Back Tap**: **Settings → Accessibility → Touch → Back Tap → Double Tap → Talk to Fin**.")
                Text("You can also add the shortcut to your Home Screen or Lock Screen as a tile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Assign a quick trigger")
            }
        case .noHardwareButton:
            Section {
                Text("Add the shortcut to your Home Screen (or the menu bar) and tap it to talk — this device has no Action Button or Back Tap.")
            } header: {
                Text("Add a tile")
            }
        }
    }

    private var triggerName: String {
        switch hardware {
        case .actionButton: return "Action Button"
        case .backTap: return "Back Tap gesture"
        case .noHardwareButton: return "Home Screen"
        }
    }

    /// One numbered step; when `copyable` is set, tapping the row copies that exact
    /// action name (matching it in the Shortcuts search box is the fiddly part).
    @ViewBuilder
    private func stepRow(_ number: Int, _ markdown: LocalizedStringKey, copyable: String? = nil) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(markdown)
            if copyable != nil {
                Spacer(minLength: 8)
                Image(systemName: copied == copyable ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(copied == copyable ? Color.green : Color.accentColor)
            }
        }
        if let copyable {
            Button { copy(copyable) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func copy(_ text: String) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = text
    }
}
