import SwiftUI
import CloudKit
#if os(iOS) || os(visionOS)
import UIKit
#else
import AppKit
#endif

struct CloudSyncStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status: CKAccountStatus = .couldNotDetermine
    @State private var checked = false

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
                    Text("Servers and SSH keys sync automatically across your devices when you're signed in to iCloud — there's no separate sign-in inside Fin.")
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
        }
    }

    private func refresh() async {
        status = (try? await CKContainer.default().accountStatus()) ?? .couldNotDetermine
        checked = true
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
        switch status {
        case .available: return "checkmark.icloud"
        case .noAccount: return "xmark.icloud"
        case .restricted: return "lock.icloud"
        case .temporarilyUnavailable: return "exclamationmark.icloud"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        status == .available ? .green : .secondary
    }

    private var statusTitle: String {
        switch status {
        case .available: return "Syncing"
        case .noAccount: return "Not Signed In"
        case .restricted: return "Restricted"
        case .temporarilyUnavailable: return "Temporarily Unavailable"
        default: return checked ? "Unknown" : "Checking…"
        }
    }

    private var statusDetail: String {
        switch status {
        case .available:
            return "Servers and keys are syncing via iCloud."
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
}
