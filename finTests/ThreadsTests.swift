import XCTest
@testable import fin

/// docs/THREADS.md §6 (app): the decoders against README-shaped fixtures, the
/// timeline merge (ordering across sources, pane party, dedupe against the
/// console's `in_reply_to` collapse), the status chip table, the default
/// selection rule, turn filtering by thread (with `thread_id` and with a
/// legacy `in_reply_to` only), the `/messages` body, and the notification
/// payload's `fin.threadId`. No network, no ModelContainer.
final class ThreadsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func iso(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: at(seconds)) }

    // MARK: - Fixtures (README "Threads")

    private func threadJSON(_ id: String, title: String, status: String, last: TimeInterval, openGoal: String? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "threadId": id, "agent": "Fin", "title": title, "status": status, "messageCount": 2,
            "lastActivityAt": iso(last), "createdAt": iso(last - 60), "participants": ["abcd1234", "iMac0001", "main:2.0"],
        ]
        if let openGoal { json["openGoal"] = openGoal }
        return json
    }

    private func messageJSON(_ id: String, thread: String?, text: String, state: String, created: TimeInterval,
                             author: String? = "abcd1234", site: String? = "Levi's iMac") -> [String: Any] {
        var json: [String: Any] = [
            "messageId": id, "agent": "Fin", "text": text, "source": "voice", "createdAt": iso(created), "state": state,
            "routedBy": "primary", "clarifyCandidates": [], "pinSiteId": NSNull(), "targetSiteId": NSNull(),
            "targetSiteName": site.map { $0 as Any } ?? NSNull(), "claimedBy": NSNull(), "claimedAt": state == "queued" ? NSNull() : iso(created + 5),
            "authorSiteId8": author.map { $0 as Any } ?? NSNull(), "appliedAt": NSNull(), "appliedRunId": state == "applied" ? "run-1" : NSNull(),
            "answeredAt": state == "answered" ? iso(created + 30) : NSNull(), "replyPreview": NSNull(),
            "pushedAt": state == "answered" ? iso(created + 31) : NSNull(),
        ]
        json["threadId"] = thread ?? id
        return json
    }

    private func eventJSON(_ thread: String, seq: Int, kind: String, actor: String, at: TimeInterval, detail: [String: Any]) -> [String: Any] {
        ["threadId": thread, "seq": seq, "agent": "Fin", "kind": kind, "actor": actor, "detail": detail, "at": iso(at)]
    }

    private func decodeMessage(_ json: [String: Any]) throws -> ControlPlaneClient.Message {
        try ControlPlaneClient.decoder.decode(ControlPlaneClient.Message.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func record(_ id: String, _ kind: AgentLogKind, _ text: String, at seconds: TimeInterval, seq: Int = 0, run: String = "r1",
                        tool: String? = nil, site: String? = "iMac0001", reply: String? = nil, thread: String? = nil, target: String? = nil) -> AgentMirrorRecord {
        AgentMirrorRecord(id: id, kind: kind, text: text, timestamp: at(seconds), sequence: seq, runID: run, toolName: tool,
                          siteID8: site, siteName: site, inReplyTo: reply, threadID: thread, target: target)
    }

    // MARK: - Decoders

    func testThreadListDecodesTheReadmeShape() throws {
        let json: [String: Any] = ["agent": "Fin", "threads": [
            threadJSON("m-root-1", title: "Check on African Intellect", status: "waiting_on_you", last: 300, openGoal: "g-followup-1"),
            threadJSON("m-root-2", title: "Deploy", status: "answered", last: 100),
            threadJSON("m-root-3", title: "Future", status: "something_new", last: 50),
        ]]
        let list = try ControlPlaneClient.decoder.decode(ThreadListResponse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(list.threads.count, 3)
        XCTAssertEqual(list.threads[0].threadId, "m-root-1")
        XCTAssertEqual(list.threads[0].status, .waitingOnYou)
        XCTAssertEqual(list.threads[0].openGoal, "g-followup-1")
        XCTAssertEqual(list.threads[0].participants, ["abcd1234", "iMac0001", "main:2.0"])
        XCTAssertEqual(list.threads[0].lastActivityAt, at(300))
        XCTAssertEqual(list.threads[1].status, .answered)
        XCTAssertNil(list.threads[1].openGoal)
        // A status this build doesn't know never fails the list.
        XCTAssertEqual(list.threads[2].status, .unknown)
        // The same shape decodes through the tvOS-side decoder too.
        let tv = try ThreadDecoding.decoder.decode(ThreadListResponse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(tv.threads.map(\.threadId), list.threads.map(\.threadId))
    }

    func testMessageRowDecodesTheThreadFields() throws {
        let answered = try decodeMessage(messageJSON("m-2", thread: "m-1", text: "and then?", state: "answered", created: 100))
        XCTAssertEqual(answered.threadId, "m-1")
        XCTAssertEqual(answered.resolvedThreadID, "m-1")
        XCTAssertEqual(answered.claimedAt, at(105))
        XCTAssertEqual(answered.pushedAt, at(131))
        XCTAssertNil(answered.appliedRunId)
        let applied = try decodeMessage(messageJSON("m-3", thread: nil, text: "root", state: "applied", created: 200))
        XCTAssertEqual(applied.appliedRunId, "run-1")
        XCTAssertEqual(applied.resolvedThreadID, "m-3")
        // A row from before threads existed: no threadId at all → its own root.
        var legacy = messageJSON("m-old", thread: nil, text: "old", state: "answered", created: 10)
        legacy.removeValue(forKey: "threadId")
        legacy.removeValue(forKey: "pushedAt"); legacy.removeValue(forKey: "claimedAt"); legacy.removeValue(forKey: "appliedRunId")
        let decoded = try decodeMessage(legacy)
        XCTAssertNil(decoded.threadId)
        XCTAssertEqual(decoded.resolvedThreadID, "m-old")
    }

    func testThreadDetailAndEventsDecode() throws {
        let detailJSON: [String: Any] = [
            "thread": threadJSON("m-1", title: "Check", status: "working", last: 400),
            "messages": [messageJSON("m-1", thread: nil, text: "Check", state: "answered", created: 0),
                         messageJSON("m-2", thread: "m-1", text: "and?", state: "applied", created: 300)],
            "events": [
                eventJSON("m-1", seq: 1, kind: "message.queued", actor: "abcd1234", at: 0, detail: ["messageId": "m-1", "source": "voice"]),
                eventJSON("m-1", seq: 2, kind: "notify.sent", actor: "iMac0001", at: 60,
                          detail: ["event": "task-complete", "title": "Done", "delivered": 2, "failed": 0, "suppressed": 0]),
                eventJSON("m-1", seq: 3, kind: "relay.sent", actor: "iMac0001", at: 20, detail: ["target": "main:2.0", "text": "run the tests", "nested": ["a": 1]]),
            ],
        ]
        let detail = try ControlPlaneClient.decoder.decode(ControlPlaneClient.ThreadDetail.self, from: JSONSerialization.data(withJSONObject: detailJSON))
        XCTAssertEqual(detail.thread.status, .working)
        XCTAssertEqual(detail.messages.map(\.messageId), ["m-1", "m-2"])
        XCTAssertEqual(detail.messages[1].threadId, "m-1")
        XCTAssertEqual(detail.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(detail.events[1].int("delivered"), 2)
        XCTAssertEqual(detail.events[1].string("event"), "task-complete")
        XCTAssertEqual(detail.events[2].string("target"), "main:2.0")
        XCTAssertEqual(detail.events[2].detailText, #"{"nested":{"a":1},"target":"main:2.0","text":"run the tests"}"#)
        XCTAssertEqual(detail.events[0].id, "m-1#1")

        let tail: [String: Any] = ["threadId": "m-1", "events": [
            eventJSON("m-1", seq: 4, kind: "goal.followup", actor: "iMac0001", at: 90, detail: ["goalId": "g-followup-1", "title": "watch it"]),
        ]]
        let events = try ControlPlaneClient.decoder.decode(ThreadEventsResponse.self, from: JSONSerialization.data(withJSONObject: tail)).events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "goal.followup")
        XCTAssertEqual(events[0].at, at(90))
        // A missing detail / actor / at never fails an event.
        let bare = try ControlPlaneClient.decoder.decode(ThreadEvent.self, from: JSONSerialization.data(withJSONObject: ["threadId": "m-1", "seq": 9, "kind": "thread.assigned"]))
        XCTAssertEqual(bare.actor, "system")
        XCTAssertNil(bare.at)
        XCTAssertEqual(bare.detail, [:])
    }

    func testMirrorRecordDecodesThreadIDAndTarget() {
        let line = #"{"id":"l1","kind":"toolCall","text":"send_session(...)","timestamp":"2026-09-12T10:00:00Z","run_id":"r","sequence":3,"tool_name":"send_session","thread_id":"m-1","target":"main:2.0"}"#
        let record = AgentMirrorRecord(jsonlLine: line)
        XCTAssertEqual(record?.threadID, "m-1")
        XCTAssertEqual(record?.target, "main:2.0")
        let legacy = AgentMirrorRecord(jsonlLine: #"{"id":"l2","kind":"userMessage","text":"hi","timestamp":"2026-09-12T10:00:00Z","in_reply_to":"m-9","thread_id":""}"#)
        XCTAssertNil(legacy?.threadID, "an empty thread_id reads as absent")
        XCTAssertEqual(legacy?.inReplyTo, "m-9")
    }

    // MARK: - Status chips and default selection

    func testStatusChipMapping() {
        XCTAssertEqual(ThreadStatus.waitingOnYou.chip, ThreadChip(label: "waiting on you", systemImage: "hand.raised", tint: .orange))
        XCTAssertEqual(ThreadStatus.stalled.chip, ThreadChip(label: "stalled", systemImage: "exclamationmark.triangle", tint: .red))
        XCTAssertEqual(ThreadStatus.working.chip, ThreadChip(label: "Fin working", systemImage: "gearshape.2", tint: .blue))
        XCTAssertEqual(ThreadStatus.answered.chip, ThreadChip(label: "answered", systemImage: "checkmark.circle", tint: .green))
        XCTAssertEqual(ThreadStatus.unknown.chip.tint, .gray)
        XCTAssertEqual(ThreadStatus(rawValue: "waiting_on_you"), .waitingOnYou)
    }

    func testDefaultSelectionIsNewestUnansweredElseNewest() {
        let answeredNewest = ThreadSummary(threadId: "m-a", title: "a", status: .answered, lastActivityAt: at(300))
        let workingOlder = ThreadSummary(threadId: "m-b", title: "b", status: .working, lastActivityAt: at(200))
        let waitingOldest = ThreadSummary(threadId: "m-c", title: "c", status: .waitingOnYou, lastActivityAt: at(100))
        XCTAssertEqual(ThreadSelection.defaultThreadID([waitingOldest, answeredNewest, workingOlder]), "m-b",
                       "the newest thread that is not answered wins, whatever order the list arrived in")
        XCTAssertEqual(ThreadSelection.defaultThreadID([answeredNewest, ThreadSummary(threadId: "m-d", title: "d", status: .answered, lastActivityAt: at(50))]), "m-a",
                       "all answered → the newest")
        XCTAssertNil(ThreadSelection.defaultThreadID([]))
        XCTAssertEqual(ThreadSelection.sorted([waitingOldest, answeredNewest, workingOlder]).map(\.threadId), ["m-a", "m-b", "m-c"])
    }

    @MainActor
    func testStoreAppliesTheDefaultRuleUntilTheUserChooses() {
        let store = ThreadStore(agentName: "Fin")
        store.merge([
            ThreadSummary(threadId: "m-a", title: "a", status: .answered, lastActivityAt: at(300)),
            ThreadSummary(threadId: "m-b", title: "b", status: .working, lastActivityAt: at(200)),
        ])
        XCTAssertEqual(store.selectedThreadID, "m-b")
        XCTAssertEqual(store.openThreads.map(\.threadId), ["m-b"])
        store.select(nil)
        store.merge([
            ThreadSummary(threadId: "m-a", title: "a", status: .answered, lastActivityAt: at(300)),
            ThreadSummary(threadId: "m-b", title: "b", status: .working, lastActivityAt: at(200)),
            ThreadSummary(threadId: "m-c", title: "c", status: .waitingOnYou, lastActivityAt: at(400)),
        ])
        XCTAssertNil(store.selectedThreadID, "an explicit All activity survives a refresh")
        store.preselect("m-c")
        XCTAssertEqual(store.selectedThread?.title, "c")
    }

    func testPickerMenuTitleCarriesChipTitleAndRelativeTime() {
        let thread = ThreadSummary(threadId: "m-1", title: String(repeating: "x", count: 60), status: .waitingOnYou, lastActivityAt: at(0))
        let title = ThreadPicker.menuTitle(thread, now: at(5 * 60))
        XCTAssertTrue(title.hasPrefix("waiting on you · "))
        XCTAssertTrue(title.hasSuffix(" · 5 min ago"))
        XCTAssertEqual(ThreadPicker.shortTitle("short"), "short")
        XCTAssertEqual(ThreadPicker.shortTitle(String(repeating: "y", count: 50), limit: 10).count, 10)
        XCTAssertEqual(ThreadPicker.relative(at(0), now: at(30)), "just now")
        XCTAssertEqual(ThreadPicker.relative(at(0), now: at(2 * 86_400)), "2 d ago")
        XCTAssertEqual(ThreadSummary(threadId: "m-1", title: "", status: .answered).displayTitle, "Untitled request")
    }

    // MARK: - Turn filtering

    private var conversation: [AgentMirrorRecord] {
        [
            // Thread m-1: a legacy turn (in_reply_to only), then a threaded turn.
            record("u1", .userMessage, "check the deploy", at: 0, seq: 1, reply: "m-1"),
            record("a1", .assistantMessage, "Deploy is green.", at: 5, seq: 2),
            record("u2", .userMessage, "and the tests?", at: 100, seq: 1, run: "r2", reply: "m-2", thread: "m-1"),
            record("t2", .toolCall, "send_session", at: 101, seq: 2, run: "r2", tool: "send_session", thread: "m-1", target: "main:2.0"),
            record("a2", .assistantMessage, "Asked the pane.", at: 105, seq: 3, run: "r2", thread: "m-1"),
            // Thread m-3, legacy (its root's in_reply_to is its own id).
            record("u3", .userMessage, "unrelated", at: 200, seq: 1, run: "r3", reply: "m-3"),
            record("a3", .assistantMessage, "ok", at: 205, seq: 2, run: "r3"),
            // A heartbeat: no thread at all.
            record("h", .userMessage, "[heartbeat] tick", at: 300, seq: 1, run: "r4"),
            record("ah", .assistantMessage, "idle", at: 301, seq: 2, run: "r4"),
        ]
    }

    func testTurnsFilterByThreadIDAndLegacyInReplyTo() {
        let all = AgentRemoteConsoleView.turns(from: conversation)
        XCTAssertEqual(all.count, 4)
        // m-2 is a non-root member of m-1; the map resolves the legacy prompt.
        let map = ["m-1": "m-1", "m-2": "m-1", "m-3": "m-3"]
        let thread1 = AgentRemoteConsoleView.turns(from: conversation, threadID: "m-1", threadOfMessage: map)
        XCTAssertEqual(thread1.map(\.id), ["u1", "u2"])
        // With no map at all: the threaded turn matches by thread_id; the legacy
        // root matches because a root's message id IS its thread id.
        let unmapped = AgentRemoteConsoleView.turns(from: conversation, threadID: "m-1")
        XCTAssertEqual(unmapped.map(\.id), ["u1", "u2"])
        let thread3 = AgentRemoteConsoleView.turns(from: conversation, threadID: "m-3")
        XCTAssertEqual(thread3.map(\.id), ["u3"])
        XCTAssertEqual(AgentRemoteConsoleView.turns(from: conversation, threadID: nil).count, 4, "nil = All activity")
        XCTAssertTrue(AgentRemoteConsoleView.turns(from: conversation, threadID: "m-nope").isEmpty)
        // A thread_id on a step alone (a turn whose user line lacks it) still counts.
        let stepOnly = [record("s1", .reasoning, "thinking", at: 1, seq: 1, run: "r9", thread: "m-7"),
                        record("s2", .assistantMessage, "done", at: 2, seq: 2, run: "r9")]
        XCTAssertEqual(ThreadMembership.threadID(of: TranscriptTurns.turns(from: stepOnly)[0], threadOfMessage: [:]), "m-7")
    }

    func testLogRunsAndLocalConsoleFilterTheSameWay() {
        let items = conversation.map(LogItem.init(record:))
        let byRun = Dictionary(grouping: items, by: \.runID)
        let r1 = byRun[AgentLogView.runUUID("r1")]!, r2 = byRun[AgentLogView.runUUID("r2")]!, r3 = byRun[AgentLogView.runUUID("r3")]!
        XCTAssertTrue(AgentLogView.runCarries(threadID: "m-1", entries: r1, threadOfMessage: [:]))
        XCTAssertTrue(AgentLogView.runCarries(threadID: "m-1", entries: r2, threadOfMessage: [:]))
        XCTAssertFalse(AgentLogView.runCarries(threadID: "m-1", entries: r3, threadOfMessage: [:]))
        XCTAssertTrue(AgentLogView.runCarries(threadID: "m-1", entries: r3.map { var e = $0; e.inReplyTo = "m-2"; e.threadID = nil; return e },
                                              threadOfMessage: ["m-2": "m-1"]), "a legacy line resolves through the row map")

        let user1 = AgentMessage(role: .user, text: "one"), reply1 = AgentMessage(role: .assistant, text: "1")
        let user2 = AgentMessage(role: .user, text: "two"), reply2 = AgentMessage(role: .assistant, text: "2")
        let system = AgentMessage(role: .system, text: "prompt")
        let messages = [system, user1, reply1, user2, reply2]
        let threads = AgentRuntime.threadIDs(for: messages, promptThreadIDs: [user2.id: "m-1"])
        XCTAssertEqual(threads[reply2.id], "m-1")
        XCTAssertEqual(threads[reply1.id], .some(nil))
        XCTAssertEqual(AgentConsoleView.visibleMessages(messages, threadID: nil, promptThreadIDs: [user2.id: "m-1"]).map(\.id), [user1.id, reply1.id, user2.id, reply2.id])
        XCTAssertEqual(AgentConsoleView.visibleMessages(messages, threadID: "m-1", promptThreadIDs: [user2.id: "m-1"]).map(\.id), [user2.id, reply2.id])
    }

    // MARK: - Timeline

    func testTimelineOrdersAcrossSourcesDetectsPanesAndDedupes() throws {
        let messages = [
            try decodeMessage(messageJSON("m-1", thread: nil, text: "check the deploy", state: "answered", created: -10)),
            try decodeMessage(messageJSON("m-2", thread: "m-1", text: "and the tests?", state: "applied", created: 95)),
            try decodeMessage(messageJSON("m-4", thread: "m-1", text: "still queued", state: "queued", created: 400, site: nil)),
        ]
        let records = [
            record("u1", .userMessage, "check the deploy", at: 0, seq: 1, reply: "m-1"),
            // The at-least-once window: the same message applied by a second body.
            record("u1b", .userMessage, "check the deploy", at: 1, seq: 1, run: "rX", site: "cloud0001", reply: "m-1"),
            record("a1", .assistantMessage, "Deploy is green.", at: 5, seq: 2),
            record("n1", .toolCall, "notify: Done — deploy is green", at: 6, seq: 3, tool: "notify"),
            record("u2", .userMessage, "and the tests?", at: 100, seq: 1, run: "r2", reply: "m-2", thread: "m-1"),
            record("t2", .toolCall, "send_session(target: main:2.0, text: run tests)", at: 101, seq: 2, run: "r2", tool: "send_session", thread: "m-1", target: "main:2.0"),
            record("r2", .toolResult, "$ swift test\nall green", at: 103, seq: 3, run: "r2", tool: "read_session", thread: "m-1"),
            record("a2", .assistantMessage, "Tests pass.", at: 105, seq: 4, run: "r2", thread: "m-1"),
        ]
        let events = [
            ThreadEvent(threadId: "m-1", seq: 1, kind: "message.queued", actor: "abcd1234", detail: ["messageId": .string("m-1")], at: at(-10)),
            ThreadEvent(threadId: "m-1", seq: 2, kind: "notify.sent", actor: "iMac0001",
                        detail: ["event": .string("task-complete"), "title": .string("Done"), "delivered": .number(2), "failed": .number(0)], at: at(7)),
            ThreadEvent(threadId: "m-1", seq: 3, kind: "relay.sent", actor: "iMac0001", detail: ["target": .string("main:2.0"), "text": .string("run tests")], at: at(101)),
            ThreadEvent(threadId: "m-1", seq: 4, kind: "notify.sent", actor: "operator",
                        detail: ["event": .string("request-input"), "title": .string("Which branch?"), "body": .string("main or release"), "delivered": .number(1)], at: at(200)),
            ThreadEvent(threadId: "m-1", seq: 5, kind: "goal.followup", actor: "iMac0001",
                        detail: ["goalId": .string("g-followup-1"), "title": .string("watch the pane"), "target": .string("main:2.0")], at: at(300)),
            ThreadEvent(threadId: "m-1", seq: 6, kind: "thread.assigned", actor: "system", detail: ["reason": .string("pane:main:2.0")], at: at(96)),
        ]
        let thread = ThreadSummary(threadId: "m-1", title: "check the deploy", status: .working)
        let items = ThreadTimeline.build(thread: thread, messages: messages, records: records, events: events)

        XCTAssertEqual(items.map(\.id), [
            "r:u1", "r:a1", "r:n1", "e:m-1#6", "r:u2", "r:t2", "r:r2", "r:a2", "e:m-1#4", "e:m-1#5", "m:m-4",
        ])
        XCTAssertEqual(items.map(\.timestamp), items.map(\.timestamp).sorted(), "ordered by time across sources")

        // The applied message is one item (the record's) carrying the row's state
        // — and the second body's duplicate application is collapsed.
        let prompt = items[0]
        XCTAssertEqual(prompt.party, .levi(deviceID8: "abcd1234"))
        XCTAssertEqual(prompt.kind, .prompt)
        XCTAssertEqual(prompt.status, ["answered", "pushed"])
        XCTAssertFalse(items.contains { $0.id == "r:u1b" || $0.id == "m:m-1" })
        XCTAssertEqual(items[4].status, ["Levi's iMac working"])

        // The site's notify line absorbs its event's delivery counts; no second row.
        XCTAssertEqual(items[2].kind, .notify)
        XCTAssertEqual(items[2].status, ["task-complete", "delivered 2"])
        XCTAssertFalse(items.contains { $0.id == "e:m-1#2" })
        // The relay event folds into the pane line; the pane is its own party both ways.
        XCTAssertEqual(items[5].party, .pane(target: "main:2.0"))
        XCTAssertEqual(items[5].kind, .relaySent)
        XCTAssertEqual(items[6].party, .pane(target: "main:2.0"), "a read_session result without a structured target still names the pane via the thread's send")
        XCTAssertFalse(items.contains { $0.id == "e:m-1#3" })
        // Operator notifications always show, as their own party.
        XCTAssertEqual(items[8].party, .operator)
        XCTAssertEqual(items[8].text, "Which branch? — main or release")
        XCTAssertEqual(items[8].status, ["request-input", "delivered 1"])
        XCTAssertEqual(items[9].party, .system)
        XCTAssertEqual(items[9].status, ["→ main:2.0"])
        XCTAssertEqual(items[3].text, "joined this thread (pane:main:2.0)")
        // A queued message that has not reached the transcript shows from the row.
        XCTAssertEqual(items[10].source, .message)
        XCTAssertEqual(items[10].status, ["queued"])
        XCTAssertEqual(ThreadParty.pane(target: "main:2.0").label, "pane main:2.0")
    }

    func testPaneTargetFallsBackToTheTextForOlderLines() {
        XCTAssertEqual(PaneRelay.target(of: record("t", .toolCall, "send_session(target: \"main:2.0\", text: \"ls\")", at: 0, tool: "send_session")), "main:2.0")
        XCTAssertEqual(PaneRelay.target(of: record("t", .toolCall, #"{"target":"work:1.1","text":"ls"}"#, at: 0, tool: "read_session")), "work:1.1")
        XCTAssertNil(PaneRelay.target(of: record("t", .toolCall, "notify: hi", at: 0, tool: "notify")))
        XCTAssertNil(PaneRelay.target(of: record("t", .toolCall, "send_session with no target", at: 0, tool: "send_session")))
        XCTAssertEqual(PaneRelay.target(of: record("t", .toolCall, "anything", at: 0, tool: "send_input", target: "main:0.0")), "main:0.0")
    }

    func testConsoleInterleavesEventsBetweenTurnsByTime() {
        let turns = TranscriptTurns.turns(from: [
            record("u1", .userMessage, "one", at: 0, seq: 1, reply: "m-1"),
            record("a1", .assistantMessage, "1", at: 5, seq: 2),
            record("u2", .userMessage, "two", at: 100, seq: 1, run: "r2", reply: "m-2"),
        ])
        let events = [
            ThreadItem(id: "e:a", party: .operator, kind: .notify, text: "n", timestamp: at(50), status: [], source: .event, sequence: 1),
            ThreadItem(id: "e:b", party: .system, kind: .event, text: "g", timestamp: at(100), status: [], source: .event, sequence: 2),
        ]
        let rows = AgentRemoteConsoleView.interleave(turns: turns, events: events)
        XCTAssertEqual(rows.map(\.id), ["t:u1", "e:a", "t:u2", "e:b"], "a turn and an event in the same second keep the turn first")
    }

    func testPendingRowsFilterByThreadButKeepUnknownOnes() {
        let known = AgentRemoteConsoleView.CloudPendingMessage(id: UUID(), text: "a", createdAt: at(0), state: .queued, threadID: "m-1")
        let other = AgentRemoteConsoleView.CloudPendingMessage(id: UUID(), text: "b", createdAt: at(0), state: .queued, threadID: "m-2")
        let unknown = AgentRemoteConsoleView.CloudPendingMessage(id: UUID(), text: "c", createdAt: at(0), state: .sending)
        XCTAssertEqual(AgentRemoteConsoleView.pendingRows([known, other, unknown], inThread: "m-1").map(\.text), ["a", "c"])
        XCTAssertEqual(AgentRemoteConsoleView.pendingRows([known, other, unknown], inThread: nil).count, 3)
    }

    // MARK: - Sending

    func testSendMessageBodyCarriesThreadIDOnlyWhenSet() {
        var context = ControlPlaneClient.MessageContext(source: "app")
        let plain = ControlPlaneClient.sendMessageBody(agent: "Fin", text: "hi", messageID: "m-x", context: context)
        XCTAssertNil(plain["threadId"])
        XCTAssertEqual(plain["messageId"] as? String, "m-x")
        context.threadID = "m-1"
        let threaded = ControlPlaneClient.sendMessageBody(agent: "Fin", text: "hi", messageID: "m-x", context: context)
        XCTAssertEqual(threaded["threadId"] as? String, "m-1")
        XCTAssertEqual(threaded["source"] as? String, "app")
        context.threadID = "  "
        XCTAssertNil(ControlPlaneClient.sendMessageBody(agent: "Fin", text: "hi", messageID: "m-x", context: context)["threadId"], "blank never sent")
    }

    func testClaimResponseThreadIDParses() throws {
        let body = try JSONSerialization.data(withJSONObject: ["granted": true, "messageId": "m-2", "threadId": "m-1"])
        XCTAssertEqual(AppSiteClient.threadID(inClaimResponse: body), "m-1")
        let old = try JSONSerialization.data(withJSONObject: ["granted": true, "messageId": "m-2"])
        XCTAssertNil(AppSiteClient.threadID(inClaimResponse: old))
        XCTAssertNil(AppSiteClient.threadID(inClaimResponse: Data("nope".utf8)))
    }

    // MARK: - Notifications

    @MainActor
    func testNotificationPayloadCarriesThreadIDThroughToTheReplyAndTheTap() async {
        let agentID = UUID()
        let userInfo: [AnyHashable: Any] = ["fin": [
            "kind": "agentReply", "agentID": agentID.uuidString, "agentName": "Fin", "messageId": "m-2", "threadId": "m-1",
        ]]
        let parsed = AgentNotificationService.parseFinPayload(userInfo)
        XCTAssertEqual(parsed?.threadID, "m-1")
        XCTAssertEqual(parsed?.messageID, "m-2")
        XCTAssertNil(AgentNotificationService.parseFinPayload(["fin": ["agentID": agentID.uuidString, "threadId": "  "]])?.threadID, "blank reads as absent")

        let service = AgentNotificationService.shared
        let originalDeliverer = service.replyDeliverer
        let originalOpen = service.onOpenAgent
        defer { service.replyDeliverer = originalDeliverer; service.onOpenAgent = originalOpen }
        var captured: (UUID, String, String, String?)?
        service.replyDeliverer = { id, name, text, thread in captured = (id, name, text, thread); return true }
        let delivered = await service.handleTypedReply("merge it", userInfo: userInfo)
        XCTAssertTrue(delivered)
        XCTAssertEqual(captured?.3, "m-1")
        XCTAssertEqual(captured?.1, "Fin")
        // A push without a thread replies without one — never a guessed thread.
        captured = nil
        _ = await service.handleTypedReply("ok", userInfo: ["fin": ["agentID": agentID.uuidString, "agentName": "Fin"]])
        XCTAssertEqual(captured?.3, .some(nil))

        // The tap deep-links with the thread.
        var opened: (UUID, String?, String?)?
        service.onOpenAgent = { id, origin, thread in opened = (id, origin, thread) }
        if let parsed { service.onOpenAgent?(parsed.agentID, parsed.originDeviceID8, parsed.threadID) }
        XCTAssertEqual(opened?.0, agentID)
        XCTAssertEqual(opened?.2, "m-1")

        // The local banner's userInfo round-trips the thread the same way.
        let local = FinCommunicationNotification.Payload.userInfo(kind: "agentReply", agentID: agentID, agentName: "Fin", threadID: "m-1")
        XCTAssertEqual(FinCommunicationNotification.Payload.parse(local)?.threadID, "m-1")
        XCTAssertNil((FinCommunicationNotification.Payload.userInfo(kind: "agentReply", agentID: agentID, agentName: "Fin")["fin"] as? [String: Any])?["threadId"])
    }

    func testNotificationsGroupUnderTheFinThreadWhenThePayloadHasOne() {
        let agentID = UUID()
        // The INSendMessageIntent conversation: thread first, then agent id, then name.
        XCTAssertEqual(FinCommunicationNotification.conversationIdentifier(agentName: "Fin", agentID: agentID, threadID: "m-1"), "m-1")
        XCTAssertEqual(FinCommunicationNotification.conversationIdentifier(agentName: "Fin", agentID: agentID, threadID: " "), agentID.uuidString)
        XCTAssertEqual(FinCommunicationNotification.conversationIdentifier(agentName: "Fin", agentID: nil, threadID: nil), "Fin")
        let intent = FinCommunicationNotification.sendMessageIntent(agentName: "Fin", agentID: agentID, body: "done", threadID: "m-1")
        XCTAssertEqual(intent.conversationIdentifier, "m-1")
        XCTAssertEqual(intent.sender?.customIdentifier, agentID.uuidString, "the recipient match still keys on the agent")
        XCTAssertEqual(FinCommunicationNotification.sendMessageIntent(agentName: "Fin", agentID: agentID, body: "done").conversationIdentifier, agentID.uuidString)

        // The local banner's thread-id: the message being answered, else the agent.
        XCTAssertEqual(AgentNotificationService.threadIdentifier(for: agentID, activeThreads: [agentID: "m-1"]), "m-1")
        XCTAssertEqual(AgentNotificationService.threadIdentifier(for: agentID, activeThreads: [:]), agentID.uuidString)
    }

    @MainActor
    func testActiveThreadIsSetAtClaimAndClearedAtAnswer() {
        let service = AgentNotificationService.shared
        let agentID = UUID()
        service.setActiveThread("m-1", for: agentID)
        XCTAssertEqual(service.activeThreads[agentID], "m-1")
        service.setActiveThread("", for: agentID)
        XCTAssertNil(service.activeThreads[agentID])
        service.setActiveThread("m-2", for: agentID)
        service.setActiveThread(nil, for: agentID)
        XCTAssertNil(service.activeThreads[agentID])
    }
}
