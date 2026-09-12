#if os(iOS)
import Foundation
import os
import ActivityKit

/// Runs the attention tile (design §3.4) from the foreground app: while the
/// scene is active it samples `SiteDirectory.shared` (the same 15 s cache the
/// console header reads), hands every sample to `FinLiveActivityPlan.Tracker`,
/// and turns its start / update / end decisions into ActivityKit calls. It
/// also keeps the control plane able to drive the tile when the app is NOT in
/// front: the per-device push-to-start token (iOS 17.2+) and each running
/// activity's update token are uploaded through `DeviceTokenUplink`, and the
/// Lambda's `_push_live_activity` uses them for `start` / `update` / `end`
/// pushes as site heartbeats change Fin's presence.
///
/// iOS only: ActivityKit's `ActivityAttributes` is unavailable on macOS and
/// the framework does not exist on visionOS. Everything is best-effort — an
/// activity that fails to start is logged and forgotten; the console header
/// and notifications still carry the same presence.
@MainActor
@available(iOS 16.2, *)
final class FinLiveActivityController {
    static let shared = FinLiveActivityController()

    private static let logger = Logger(subsystem: "dev.levischoen.fin", category: "LiveActivity")
    static let pollInterval: Duration = .seconds(15)
    static let startTokenKind = "activity-start"
    static let updateTokenKind = "activity-update"

    private(set) var tracker = FinLiveActivityPlan.Tracker()
    private var activity: Activity<FinActivityAttributes>?
    private var pollLoop: Task<Void, Never>?
    private var tokenObservers: [Task<Void, Never>] = []
    private var didInstallObservers = false

    private init() {}

    // MARK: - Scene phase

    /// Called on every foregrounding (RootView's scenePhase observer).
    func appDidBecomeActive() {
        guard !TestHost.isUnitTest, CloudControlPlaneConfig.isConfigured else { return }
        // The fin-widgets extension's floor is iOS 18 (project.yml): below it
        // there is nothing to render a requested activity, so don't request.
        guard #available(iOS 18.0, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        installObserversIfNeeded()
        adoptExistingActivity()
        guard pollLoop == nil else { return }
        pollLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                let sites = await SiteDirectory.shared.refresh()
                self.apply(presence: FinPresence.fold(sites), agentName: Self.agentName(of: sites))
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The tile outlives the foreground on purpose — that is the whole point
    /// of a Live Activity — so only the local sampling stops here. The
    /// control plane's pushes take over until the next foregrounding.
    func appDidEnterBackground() {
        pollLoop?.cancel()
        pollLoop = nil
    }

    // MARK: - Decisions → ActivityKit

    func apply(presence: FinPresence, agentName: String, now: Date = Date()) {
        switch tracker.step(presence, now: now) {
        case .nothing:
            return
        case .start(let state):
            start(state: state, agentName: agentName)
        case .update(let state):
            update(state: state)
        case .end(let state):
            end(state: state)
        }
    }

    private func start(state: FinActivityAttributes.ContentState, agentName: String) {
        let attributes = FinActivityAttributes(agentName: agentName, agentID: "")
        do {
            let started = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: .token
            )
            observe(started)
            Self.logger.info("live activity started (\(state.status.rawValue, privacy: .public))")
        } catch {
            // Denied in Settings, too many activities, or a simulator quirk —
            // the header and notifications still carry the same presence.
            tracker.activityEnded()
            Self.logger.warning("live activity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func update(state: FinActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func end(state: FinActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }

    // MARK: - Activities started elsewhere (push-to-start, a previous launch)

    private func adoptExistingActivity() {
        guard activity == nil else { return }
        // The most recent live one wins; ActivityKit lists them unordered, so
        // sort by our own timestamp. Any extras are ended: the control plane
        // pushes to every update token it has and would otherwise keep two
        // tiles alive.
        let live = Activity<FinActivityAttributes>.activities
            .filter { $0.activityState == .active }
            .sorted { $0.content.state.updatedAt > $1.content.state.updatedAt }
        guard let newest = live.first else { return }
        for extra in live.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        observe(newest)
        tracker = FinLiveActivityPlan.Tracker(isRunning: true, lastState: newest.content.state)
    }

    private func observe(_ started: Activity<FinActivityAttributes>) {
        activity = started
        let id = started.id
        tokenObservers.append(Task { [weak self] in
            for await token in started.pushTokenUpdates {
                let ok = await DeviceTokenUplink.registerLiveActivityToken(token, kind: Self.updateTokenKind, activityID: id)
                Self.logger.info("activity update token \(ok ? "registered" : "not registered", privacy: .public)")
                _ = self
            }
        })
        tokenObservers.append(Task { [weak self] in
            for await state in started.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, self.activity?.id == id else { return }
                self.activity = nil
                self.tracker.activityEnded()
                return
            }
        })
    }

    private func installObserversIfNeeded() {
        guard !didInstallObservers else { return }
        didInstallObservers = true
        // Activities the control plane starts by push while the app is closed
        // surface here; adopting them is what makes their update token reach
        // the control plane too.
        tokenObservers.append(Task { [weak self] in
            for await pushed in Activity<FinActivityAttributes>.activityUpdates {
                guard let self else { return }
                if self.activity == nil {
                    self.observe(pushed)
                    self.tracker = FinLiveActivityPlan.Tracker(isRunning: true, lastState: pushed.content.state)
                }
            }
        })
        if #available(iOS 17.2, *) {
            tokenObservers.append(Task {
                for await token in Activity<FinActivityAttributes>.pushToStartTokenUpdates {
                    let ok = await DeviceTokenUplink.registerLiveActivityToken(token, kind: Self.startTokenKind, activityID: nil)
                    Self.logger.info("push-to-start token \(ok ? "registered" : "not registered", privacy: .public)")
                }
            })
        }
    }

    /// The agent name the tile is titled with: the agent of the site that is
    /// busiest, else the first live site's, else "Fin".
    static func agentName(of sites: [FinSite]) -> String {
        let live = sites.filter { $0.live && $0.state != "retired" }
        let busy = live.first { $0.state == "needs-input" } ?? live.first { $0.state == "working" } ?? live.first
        let name = busy?.agent.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Fin" : name
    }
}
#endif
