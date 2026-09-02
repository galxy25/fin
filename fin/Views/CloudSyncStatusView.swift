import SwiftUI
import CloudKit
import CoreData
#if os(iOS) || os(visionOS)
import UIKit
#else
import AppKit
#endif

/// Tracks what the CloudKit mirror is actually doing, not just whether an iCloud account
/// exists. SwiftData's sync runs on an internal NSPersistentCloudKitContainer, but that
/// container posts its import/export events through the shared NotificationCenter — so
/// real sync state is observable from outside without owning the container. This is what
/// separates "Synced 2 minutes ago" from the permanently-lying "Syncing" label this view
/// used to show whenever an account was merely signed in.
@MainActor
final class CloudSyncActivityMonitor: ObservableObject {
    static let shared = CloudSyncActivityMonitor()

    enum Activity: Equatable {
        case idle
        case inFlight
        case succeeded(Date)
        case failed(String, Date)
    }

    @Published private(set) var activity: Activity = .idle

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        guard let endDate = event.endDate else {
            activity = .inFlight
            return
        }
        if let error = event.error {
            activity = .failed(error.localizedDescription, endDate)
        } else {
            activity = .succeeded(endDate)
        }
    }
}

struct CloudSyncStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = CloudSyncActivityMonitor.shared
    @State private var status: CKAccountStatus = .couldNotDetermine
    @State private var checked = false
    @State private var probeResult: String?
    @State private var isProbing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.title2)
                            .foregroundStyle(statusColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle).font(.headline)
                            Text(statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Servers, SSH keys, and agents sync automatically across your devices when you're signed in to iCloud — there's no separate sign-in inside Fin. Pull down to check iCloud directly.")
                }

                Section {
                    if let probeResult {
                        Text(probeResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(isProbing ? "Checking iCloud\u{2026}" : "Check iCloud Now") {
                        Task { await probeCloud() }
                    }
                    .disabled(isProbing || status != .available)
                }

                if status != .available {
                    Section {
                        Button("Open iCloud Settings", action: openSystemSettings)
                    }
                }
            }
            .navigationTitle("iCloud Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refresh() }
            .refreshable {
                await refresh()
                await probeCloud()
            }
        }
    }

    private func refresh() async {
        status = (try? await CKContainer.default().accountStatus()) ?? .couldNotDetermine
        checked = true
    }

    /// Asks CloudKit directly whether the sync zone exists in this account's private
    /// database — ground truth for "has any device actually uploaded data", independent
    /// of what the local mirror has or hasn't done this launch. A zone fetch needs no
    /// queryable indexes, so it works regardless of schema details.
    private func probeCloud() async {
        isProbing = true
        defer { isProbing = false }
        do {
            let zones = try await CKContainer.default().privateCloudDatabase.allRecordZones()
            if zones.contains(where: { $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone" }) {
                probeResult = "iCloud has Fin data: another device has uploaded, or this one already exported."
            } else {
                probeResult = "No Fin data in iCloud yet — no device has completed an upload to this account."
            }
        } catch {
            probeResult = "iCloud check failed: \(error.localizedDescription)"
        }
    }

    private func openSystemSettings() {
        #if os(iOS) || os(visionOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private var statusIcon: String {
        guard status == .available else {
            switch status {
            case .noAccount: return "xmark.icloud"
            case .restricted: return "lock.icloud"
            case .temporarilyUnavailable: return "exclamationmark.icloud"
            default: return "questionmark.circle"
            }
        }
        switch monitor.activity {
        case .idle, .inFlight: return "arrow.triangle.2.circlepath.icloud"
        case .succeeded: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    private var statusColor: Color {
        guard status == .available else { return .secondary }
        switch monitor.activity {
        case .succeeded: return .green
        case .failed: return .orange
        case .idle, .inFlight: return .secondary
        }
    }

    private var statusTitle: String {
        guard status == .available else {
            switch status {
            case .noAccount: return "Not Signed In"
            case .restricted: return "Restricted"
            case .temporarilyUnavailable: return "Temporarily Unavailable"
            default: return checked ? "Unknown" : "Checking\u{2026}"
            }
        }
        switch monitor.activity {
        case .idle: return "Waiting to Sync"
        case .inFlight: return "Syncing\u{2026}"
        case .succeeded: return "Synced"
        case .failed: return "Sync Problem"
        }
    }

    private var statusDetail: String {
        guard status == .available else {
            switch status {
            case .noAccount:
                return "Sign in to iCloud in Settings to sync your servers and keys across devices."
            case .restricted:
                return "iCloud is restricted on this device (parental controls or an MDM profile)."
            case .temporarilyUnavailable:
                return "iCloud is temporarily unavailable. Fin will sync automatically once it's back."
            default:
                return "Unable to determine iCloud status."
            }
        }
        switch monitor.activity {
        case .idle:
            return "Signed in; no sync activity yet this launch."
        case .inFlight:
            return "Transferring changes with iCloud now."
        case .succeeded(let date):
            return "Last synced \(date.formatted(.relative(presentation: .named)))."
        case .failed(let message, let date):
            return "\(message) (\(date.formatted(.relative(presentation: .named))))"
        }
    }
}
