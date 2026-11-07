import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's half of `FinShareMirror` (app target only — it reads the real
/// `CloudControlPlaneConfig` and the synced agents). Refreshed at launch, on
/// every credential change, when the control-plane config changes, and each
/// time the app comes forward or goes away — a token iCloud Keychain delivered
/// from another device, or agents CloudKit synced in after launch, reach the
/// share sheet by the next time the user leaves the app.
extension FinShareMirror {
    /// Credentials only — safe from any thread (`setToken` is not main-bound).
    static func mirrorCredentials() {
        guard !ScreenshotFixtures.isEnabled, let store = Store.live else { return }
        var current = read(from: store) ?? Snapshot(endpointURL: "", token: "", agentName: nil, deviceID8: DeviceIdentity.short)
        current.endpointURL = CloudControlPlaneConfig.endpointURL
        current.token = CloudControlPlaneConfig.token
        current.deviceID8 = DeviceIdentity.short
        current.agentName = nil
        write(current, to: store)
    }

    @MainActor
    static func refreshFromApp() {
        guard !ScreenshotFixtures.isEnabled, let store = Store.live else { return }
        write(Snapshot(
            endpointURL: CloudControlPlaneConfig.endpointURL,
            token: CloudControlPlaneConfig.token,
            agentName: FinThreadDirectory.primaryAgentName(),
            deviceID8: DeviceIdentity.short
        ), to: store)
    }

    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    @MainActor
    static func activate() {
        guard observers.isEmpty, Store.live != nil else { return }
        // Touch the current-thread store now so its one-time migration into
        // the group happens at launch, not at the first share.
        _ = XanaduCurrentThread.defaults
        refreshFromApp()
        var names: [Notification.Name] = [CloudControlPlaneConfig.changedNotification]
        #if canImport(UIKit)
        names += [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification]
        #elseif canImport(AppKit)
        names += [NSApplication.didBecomeActiveNotification, NSApplication.willResignActiveNotification]
        #endif
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refreshFromApp() }
            }
        }
    }
}
