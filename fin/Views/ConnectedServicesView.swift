import SwiftUI
import SwiftData

/// Manages the third-party credentials a cloud worker uses while driving a task
/// — a Gmail app password, an App Store Connect key — held in the user's own AWS
/// Secrets Manager behind the control plane's write-only `/secrets` routes.
///
/// The screen's whole design follows from one fact: **a stored value can never
/// come back.** No control-plane route returns one and the Lambda's role holds no
/// `GetSecretValue`, so there is nothing to show, nothing to prefill, and no
/// "reveal" affordance to build. That makes the list a metadata list (service,
/// kind, scope, timestamps) and makes "update" a full re-entry, which the sheet
/// says out loud rather than letting a user discover it by wiping their username.
///
/// The typed value's entire lifetime is one `@State` string on
/// `ServiceCredentialSheet`: bound to a `SecureField`, handed to
/// `ServiceCredentialsClient.storeSecret`, cleared on a successful store, kept
/// on a failed one only so a retry doesn't force a re-paste — and cleared
/// unconditionally when the sheet dismisses, which bounds its lifetime to the
/// sheet's. It is never written to UserDefaults, SwiftData, or the Keychain,
/// never logged, and never interpolated into an error message.
struct ConnectedServicesView: View {
    /// Scope choices beyond `shared`: an agent's display name, which the Lambda
    /// lowercases to the key slug a worker reads.
    @Query(sort: \Agent.name) private var agents: [Agent]

    @State private var rows: [ServiceCredentialsClient.Metadata] = []
    @State private var loadState: LoadState = .idle
    @State private var sheet: SheetTarget?
    @State private var pendingDeletion: ServiceCredentialsClient.Metadata?
    @State private var banner: String?

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Which sheet is up. `.update` carries only METADATA — there is no value to
    /// carry, which is exactly why the update copy demands a full re-entry.
    private enum SheetTarget: Identifiable {
        case add
        case update(ServiceCredentialsClient.Metadata)

        var id: String {
            switch self {
            case .add: return "add"
            case .update(let row): return "update/" + row.id
            }
        }
    }

    var body: some View {
        Form {
            if !CloudControlPlaneConfig.isConfigured {
                Section {
                    Text(ServiceCredentialsClient.Failure.notConfigured.userMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            listSection
            addSection
            footerSection
        }
        .navigationTitle("Connected Services")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $sheet) { target in
            sheetView(for: target)
        }
        .confirmationDialog(
            "Delete credential?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Schedule Deletion", role: .destructive) {
                if let row = pendingDeletion { Task { await delete(row) } }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deletionPrompt)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listSection: some View {
        Section {
            switch loadState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await reload() } }
                }
            case .loaded:
                if rows.isEmpty {
                    Text("No credentials stored yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        credentialRow(row)
                    }
                }
            }
            if let banner {
                Text(banner).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Stored Credentials")
        } footer: {
            Text("Metadata only — this list is everything the app can see. "
                + "Values are never returned by the control plane.")
        }
    }

    private func credentialRow(_ row: ServiceCredentialsClient.Metadata) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.service).font(.body.weight(.medium))
                Text(kindLabel(row.kind))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Spacer()
                Text(row.agentScope).font(.caption).foregroundStyle(.secondary)
            }
            if let label = row.label, !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(timestampLine(row)).font(.caption2).foregroundStyle(.secondary)
            if row.isStale() {
                Text("Older than \(ServiceCredentialsClient.Metadata.staleAfterDays) days — "
                    + "consider replacing it with a freshly minted one.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let deletion = row.deletionScheduled {
                Text("Deletion scheduled — recoverable until \(displayDate(deletion)). "
                    + "Storing a new value before then restores and replaces it.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 16) {
                Button("Replace Value…") { sheet = .update(row) }
                Button("Delete…", role: .destructive) { pendingDeletion = row }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private var addSection: some View {
        Section {
            Button("Add Credential…") { sheet = .add }
                .disabled(!CloudControlPlaneConfig.isConfigured)
        }
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Credentials are encrypted in your own AWS Secrets Manager, under "
                + "your account. This app can write them but can NEVER read them "
                + "back — no route returns a value, and the control plane's role "
                + "has no permission to fetch one, so a stored value cannot be "
                + "shown here or anywhere else in the app. A cloud worker reads a "
                + "credential only while it is driving a task that needs it. "
                + "Prefer, in order: an OAuth token, an app-specific password "
                + "(like Gmail's), then an API key. Use your account's primary "
                + "password only as a last resort — the first three are revocable "
                + "on their own and limit a compromised worker to one service "
                + "instead of your whole identity.")
        }
    }

    // MARK: - Sheet

    @ViewBuilder
    private func sheetView(for target: SheetTarget) -> some View {
        switch target {
        case .add:
            ServiceCredentialSheet(
                existing: nil,
                agentNames: agents.map(\.name).filter { !$0.isEmpty },
                onStored: { message in
                    banner = message
                    sheet = nil
                    Task { await reload() }
                },
                onCancel: { sheet = nil }
            )
        case .update(let row):
            ServiceCredentialSheet(
                existing: row,
                agentNames: agents.map(\.name).filter { !$0.isEmpty },
                onStored: { message in
                    banner = message
                    sheet = nil
                    Task { await reload() }
                },
                onCancel: { sheet = nil }
            )
        }
    }

    // MARK: - Actions

    private func reload() async {
        if case .loaded = loadState {} else { loadState = .loading }
        switch await ServiceCredentialsClient.listSecrets() {
        case .success(let list):
            rows = list
            loadState = .loaded
        case .failure(let failure):
            rows = []
            loadState = .failed(failure.userMessage)
        }
    }

    private func delete(_ row: ServiceCredentialsClient.Metadata) async {
        pendingDeletion = nil
        switch await ServiceCredentialsClient.deleteSecret(
            service: row.service, agentScope: row.agentScope
        ) {
        case .success(let ack):
            banner = ack.deletionDate.map {
                "\(row.service) is scheduled for deletion — recoverable until "
                    + "\(displayDate($0))."
            } ?? "\(row.service) is scheduled for deletion."
        case .failure(let failure):
            banner = failure.userMessage
        }
        await reload()
    }

    // MARK: - Presentation helpers

    private var deletionDialogBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var deletionPrompt: String {
        guard let row = pendingDeletion else { return "" }
        // Future tense on purpose: this is the confirmation, asked before
        // anything has happened.
        return "\(row.service) (\(row.agentScope)) will be scheduled for deletion "
            + "with a 7-day recovery window: workers lose access immediately, and "
            + "AWS erases it permanently 7 days from now. Storing a new value for "
            + "the same service before then restores and replaces it."
    }

    private func kindLabel(_ raw: String) -> String {
        ServiceCredentialsClient.SecretKind(rawValue: raw)?.label ?? raw
    }

    private func timestampLine(_ row: ServiceCredentialsClient.Metadata) -> String {
        let updated = row.lastUpdatedDate
            .map { $0.formatted(date: .abbreviated, time: .omitted) }
            ?? row.lastUpdated ?? "unknown"
        let accessed = row.lastAccessed.map { "last read by a worker \($0)" }
            ?? "never read by a worker"
        return "Updated \(updated) · \(accessed)"
    }

    private func displayDate(_ iso: String) -> String {
        ISO8601DateFormatter().date(from: iso)
            .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? iso
    }
}

/// Add-or-replace form. One sheet serves both because the control plane has one
/// verb: `PUT` writes the whole secret, so "update" is not a patch — it is a
/// fresh, complete entry. The only difference is the copy and a locked service
/// name.
///
/// Value handling, exhaustively: `value` and `username` are `@State` strings that
/// exist only while this sheet is on screen. `submit()` passes them to the client;
/// a successful store clears both immediately, a failed one keeps them (an error
/// the user can retry shouldn't demand a re-paste), and `clearSecrets()` runs
/// unconditionally from `.onDisappear`, so a cancel, a swipe-down, or a failed
/// submit the user walks away from all end with the state empty. No branch copies
/// either string anywhere else — not into `error`, not into a log, not into any
/// store.
private struct ServiceCredentialSheet: View {
    /// `nil` = add; a row = replace that credential's value (metadata only —
    /// there is no stored value to hand this sheet).
    let existing: ServiceCredentialsClient.Metadata?
    let agentNames: [String]
    let onStored: (String) -> Void
    let onCancel: () -> Void

    @State private var service: String = ""
    @State private var scope: String = ServiceCredentialsClient.sharedScope
    @State private var kind: ServiceCredentialsClient.SecretKind = .appPassword
    @State private var username: String = ""
    @State private var value: String = ""
    @State private var note: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if existing != nil { replaceNotice }
                identitySection
                secretSection
                labelSection
                if let error {
                    Section {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Credential" : "Replace Value")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Store" : "Replace") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .disabled(isSubmitting)
        }
        .onAppear(perform: prefillMetadata)
        // The sheet's lifetime is the value's lifetime. Keeping the typed value
        // across a failed submit is deliberate (a retry shouldn't make the user
        // paste it again), but dismissing ends it unconditionally.
        .onDisappear(perform: clearSecrets)
    }

    private var replaceNotice: some View {
        Section {
            Text("Stored values can't be shown. The control plane never returns a "
                + "credential, so this form starts empty and what you type "
                + "REPLACES the whole credential — re-enter the value, and the "
                + "username too if this credential has one. Anything you leave "
                + "blank is dropped, not kept.")
                .font(.callout)
        }
    }

    private var identitySection: some View {
        Section {
            if let existing {
                LabeledContent("Service", value: existing.service)
                LabeledContent("Used by", value: existing.agentScope)
            } else {
                TextField("Service (e.g. gmail)", text: $service)
                    .autocapitalizationNeverIfAvailable()
                    .disableAutocorrection(true)
                Picker("Used by", selection: $scope) {
                    Text("All agents (shared)").tag(ServiceCredentialsClient.sharedScope)
                    ForEach(agentNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            Picker("Kind", selection: $kind) {
                ForEach(ServiceCredentialsClient.SecretKind.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } header: {
            Text("Service")
        } footer: {
            Text(serviceFooter)
        }
    }

    private var secretSection: some View {
        Section {
            TextField("Username (optional)", text: $username)
                .autocapitalizationNeverIfAvailable()
                .disableAutocorrection(true)
            SecureField("Value", text: $value)
        } header: {
            Text("Credential")
        } footer: {
            Text("The value is encrypted in your AWS Secrets Manager and can never "
                + "be read back into this app. It is not saved on this device — "
                + "when this sheet closes, what you typed is gone.")
        }
    }

    private var labelSection: some View {
        Section {
            TextField("Label (optional)", text: $note)
        } footer: {
            Text("A reminder of what this credential is for. Unlike the value, the "
                + "label is NOT encrypted — it's plain metadata on the secret, so "
                + "never put any part of a credential in it.")
        }
    }

    private var serviceFooter: String {
        if existing != nil {
            return "The service and scope identify which credential is being "
                + "replaced, so they can't be changed here."
        }
        return "Lowercase letters, digits, and hyphens (up to 40 characters). "
            + "\"All agents\" stores it in the shared scope every worker can read; "
            + "pick an agent to scope it to that agent's workers."
    }

    private var effectiveService: String {
        existing?.service ?? service.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !value.isEmpty
            && ServiceCredentialsClient.isValidServiceName(effectiveService)
    }

    private func prefillMetadata() {
        // Metadata only, and only on the replace path. There is deliberately no
        // value or username to prefill: neither is retrievable, and pretending
        // otherwise is how a user ends up silently wiping the username.
        guard let existing else { return }
        service = existing.service
        scope = existing.agentScope
        kind = ServiceCredentialsClient.SecretKind(rawValue: existing.kind) ?? .appPassword
        note = existing.label ?? ""
    }

    private func submit() async {
        error = nil
        isSubmitting = true
        let outcome = await ServiceCredentialsClient.storeSecret(
            service: effectiveService,
            agentScope: existing?.agentScope ?? scope,
            kind: kind,
            value: value,
            username: username,
            note: note
        )
        isSubmitting = false
        switch outcome {
        case .success(let ack):
            clearSecrets()
            onStored("Stored \(ack.service) for \(ack.agentScope).")
        case .failure(let failure):
            // Carries the client's user-facing text only — field names at most,
            // never any part of what was typed into the value field.
            error = failure.userMessage
        }
    }

    /// The only two fields that can hold credential material. Called on success
    /// and unconditionally on dismiss.
    private func clearSecrets() {
        value = ""
        username = ""
    }
}
