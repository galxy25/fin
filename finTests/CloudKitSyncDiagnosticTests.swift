import XCTest
import SwiftData
import CoreData
import CloudKit
@testable import fin

/// On-device CloudKit sync diagnostic, not a test of app behavior: exercises a real
/// CloudKit-backed store on whatever device runs it and dumps the mirror's full event
/// errors — including the per-item errors nested inside a CKError.partialFailure, which
/// is where the actual server rejection reason lives. Built to chase a persistent
/// `_pcs_data BAD_REQUEST` that the CloudKit Console shows only from the server side.
///
/// Run against a specific device:
///
///   TEST_RUNNER_FIN_SYNC_DIAGNOSTIC=1 xcodebuild test -scheme fin \
///     -destination 'platform=iOS,id=<device-udid>' \
///     -only-testing:finTests/CloudKitSyncDiagnosticTests
final class CloudKitSyncDiagnosticTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FIN_SYNC_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Sync diagnostic runs only when FIN_SYNC_DIAGNOSTIC=1.")
        }
    }

    @MainActor
    func testExerciseCloudKitMirrorAndDumpErrors() async throws {
        // Account state first — a keychain/identity problem often shows up here already.
        let accountStatus = try await CKContainer(identifier: "iCloud.dev.levischoen.fin").accountStatus()
        print("FIN-DIAG accountStatus: \(accountStatus.rawValue) (0=couldNotDetermine 1=available 2=restricted 3=noAccount 4=temporarilyUnavailable)")

        var observedErrors: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            let phase = event.endDate == nil ? "started" : "finished"
            print("FIN-DIAG event type=\(event.type.rawValue) (0=setup 1=import 2=export) \(phase) succeeded=\(event.succeeded)")
            if let error = event.error {
                let dump = Self.dump(error as NSError)
                observedErrors.append(dump)
                print("FIN-DIAG error:\n\(dump)")
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-sync-diag-\(UUID().uuidString).store")
        let config = ModelConfiguration(
            "SyncDiagnostic",
            schema: Schema([AgentMemory.self]),
            url: storeURL,
            cloudKitDatabase: .private("iCloud.dev.levischoen.fin")
        )
        let container = try ModelContainer(
            for: Schema([AgentMemory.self]),
            configurations: [config]
        )
        let context = container.mainContext

        let probe = AgentMemory(
            kind: .episodic,
            title: "sync diagnostic probe",
            content: "Written only to force a real export and surface its errors.",
            tags: "sync-diagnostic"
        )
        context.insert(probe)
        try context.save()

        // Long enough for setup + export (+ the PCS bootstrap that has been failing).
        try await Task.sleep(for: .seconds(30))

        context.delete(probe)
        try? context.save()

        print("FIN-DIAG total errored events: \(observedErrors.count)")
        // Deliberately no assertion on success/failure: the run's value is the printed
        // error dumps either way, and a red test would bury them behind a failure banner.
    }

    /// Flattens an NSError including CloudKit's nested partial-failure dictionaries,
    /// which is where "error 2" actually explains itself.
    private static func dump(_ error: NSError, indent: String = "  ") -> String {
        var lines = ["\(indent)\(error.domain) code=\(error.code): \(error.localizedDescription)"]
        for (key, value) in error.userInfo {
            if key == CKPartialErrorsByItemIDKey, let partials = value as? [AnyHashable: NSError] {
                lines.append("\(indent)partial errors (\(partials.count)):")
                for (item, itemError) in partials {
                    lines.append("\(indent)  item \(item):")
                    lines.append(dump(itemError, indent: indent + "    "))
                }
            } else if let nested = value as? NSError {
                lines.append("\(indent)\(key) ->")
                lines.append(dump(nested, indent: indent + "  "))
            } else {
                lines.append("\(indent)\(key) = \(String(describing: value).prefix(300))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
