import XCTest

// Ported from PocketDJ's apple/Tests/UI/XCUIHelpers.swift — the cross-feature helpers
// only. PocketDJ's fixture/catalog-shaped helpers (search-field reveals, sheet-dismiss
// chains, ⌘-shortcut browser drivers, etc.) encode that app's specific navigation
// surfaces and have no Fin equivalent; they were left out rather than copied. Add
// Fin-specific helpers here as they're needed, following the same techniques.

/// Launches Fin with `FIN_UI_TESTING=1` set, and returns the launched app. Use this
/// instead of `XCUIApplication().launch()` directly in every new test.
///
/// Why this exists: `finApp.swift` skips its CloudKit push-subscription setup
/// (`AgentSignalSubscriber.ensureSubscriptions()`) when this flag is present.
/// `CKContainer(identifier:)` traps outright — a non-throwing, non-catchable crash
/// inside Apple's own framework — whenever the running binary's code signature
/// lacks a valid CloudKit container entitlement, which an ad-hoc-signed UI test
/// run (see `scripts/test-macos.sh` / `.claude/skills/apple-test/SKILL.md`) never
/// has. `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]` was
/// tried first and does NOT work for this: it's reliably set on a unit-test host
/// process (same process as the app), but a UI test's app-under-test is a
/// genuinely separate process `XCUIApplication.launch()` spawns, and that env var
/// is not propagated to it — confirmed live, the crash still reproduced with that
/// check in place. An explicit `launchEnvironment` flag is the reliable way.
@discardableResult
func launchFinApp(configure: (XCUIApplication) -> Void = { _ in }) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["FIN_UI_TESTING"] = "1"
    configure(app)
    app.launch()
    return app
}

extension XCUIApplication {
    /// Look up an interactive control by accessibility identifier or label.
    /// In-content + sheet controls are plain `Button`/`NavigationLink`, so a
    /// `.buttons` query resolves them on iPhone, iPad, and Mac and stays lazy
    /// (so `waitForExistence` works for controls that appear later).
    func el(_ key: String) -> XCUIElement { buttons[key] }

    /// Look up ANY element (button, static text, scroll view, …) by accessibility
    /// identifier. Used for non-button surfaces — a plain view with `.onTapGesture`,
    /// a List row, a sidebar, a disclosure group's content — not just `Button`s.
    func any(_ key: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: key).firstMatch
    }

    /// Scroll-aware existence wait for LAZY containers (Form/List): off-screen rows
    /// don't exist in the a11y tree, and splitting a "swipe until exists" loop from a
    /// follow-up `waitForExistence` RACES — under heavy host load a mid-animation
    /// snapshot can transiently report the row, the loop exits, the scroll then
    /// settles back off-screen, and a trailing wait (which itself never scrolls)
    /// starves for its whole timeout. Alternating short waits with swipes keeps the
    /// scroll and the wait from diverging.
    ///
    /// iOS/iPadOS only IN PRACTICE — `swipeUp()` on the Application element can't
    /// resolve a hit point on macOS, so every swipe throws. It carries no `#if` of
    /// its own because it compiles everywhere; a macOS-running caller must fence
    /// itself (or take a touch-free path) rather than un-fence this.
    @discardableResult
    func swipeTo(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }
        for _ in 0..<maxSwipes {
            swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }
}

// MARK: - macOS idiom bridges
//
// XCUITest speaks UIKit natively; on macOS the SAME SwiftUI view lands on a different
// AppKit control with a different accessibility shape. These bridges keep ONE test body
// working on every platform instead of forcing an `#if !os(macOS)` fence. The three
// mappings that account for nearly every macOS-only UI-test failure in this repo:
//
//   SwiftUI view            iOS a11y element         macOS a11y element
//   ─────────────────────   ──────────────────────   ────────────────────────────
//   Picker(.segmented)      Button per segment       NOT a Button / SegmentedControl
//   Toggle                  Switch, value "0"/"1"    NOT a Switch; value isn't a String
//   Text                    string in `label`        `label` works for short rows;
//                                                    a wrapped headline does not
//
// SCOPE OF THE EVIDENCE — read this before trusting the right-hand column. This table
// (and the bridges below) is ported verbatim from PocketDJ, where it was derived from
// that app's own macOS failure output: `buttons["Artists"]`, a segmented-control query,
// a `switches[…].value as? String` and a `label CONTAINS` predicate on a wrapped
// headline each resolved to nothing/nil on macOS while working on iOS there. The exact
// AppKit class each one maps TO was never established, so every bridge is written
// type-AGNOSTIC (match by identifier across all element types, or accept label OR
// value) rather than betting on a specific replacement type. Don't "tidy" one of these
// into a single concrete query on the strength of this comment — verify against Fin's
// own macOS failure output first if a bridge here doesn't resolve.

extension XCUIApplication {
    /// One option of a segmented `Picker`, by its VISIBLE LABEL. On iOS each segment is
    /// a `Button`; on macOS (per PocketDJ's measurement) it is not, so the query is left
    /// type-agnostic — match the label across every element type — rather than betting
    /// on a particular AppKit class. Lazy on both, so `waitForExistence` still works for
    /// a picker that appears later.
    func segment(_ label: String) -> XCUIElement {
        #if os(macOS)
        return descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
            .firstMatch
        #else
        return buttons[label].firstMatch
        #endif
    }

    /// A SwiftUI `Toggle` by accessibility identifier. On macOS a Toggle isn't a
    /// `Switch` in the way iOS exposes one, so match by identifier across ALL element
    /// types instead of naming a replacement class.
    func toggleEl(_ key: String) -> XCUIElement {
        #if os(macOS)
        return descendants(matching: .any).matching(identifier: key).firstMatch
        #else
        return switches[key].firstMatch
        #endif
    }

    /// Any element whose VISIBLE TEXT contains `text`, matching `label` OR `value` —
    /// on macOS a `label CONTAINS` predicate can miss a wrapped/multi-line row that a
    /// short single-line row in the same list matches fine by label. Matching both
    /// fields is correct everywhere and costs nothing.
    func textContaining(_ text: String) -> XCUIElement {
        staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    /// Exact visible text, matching `label` OR `value` for the same reason as
    /// `textContaining`.
    func textEqual(_ text: String) -> XCUIElement {
        staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", text, text)
        ).firstMatch
    }

    /// Pop one level of a pushed detail stack / navigation. Deliberately does NOT fall
    /// back to "tap the toolbar's first button" on macOS: a window toolbar can carry
    /// other actions (New Window, etc.), and a blind boundBy-0 tap can fire the wrong
    /// one — it returns `false` so the caller's own assertion fails honestly instead of
    /// the test wandering into a stray window/action.
    @discardableResult
    func goBack(timeout: TimeInterval = 5) -> Bool {
        #if os(macOS)
        let back = buttons["Back"].firstMatch
        guard back.waitForExistence(timeout: timeout) else { return false }
        back.tap()
        return true
        #else
        let back = navigationBars.buttons.element(boundBy: 0)
        guard back.waitForExistence(timeout: timeout) else { return false }
        back.tap()
        return true
        #endif
    }
}

extension XCUIElement {
    /// A Toggle's on/off state, normalized: iOS reports the String "0"/"1"; a macOS
    /// CheckBox reports an NSNumber. `nil` when the element exposes no readable state
    /// at all.
    var isToggledOn: Bool? {
        if let s = value as? String {
            if s == "1" || s.caseInsensitiveCompare("on") == .orderedSame { return true }
            if s == "0" || s.caseInsensitiveCompare("off") == .orderedSame { return false }
            return nil
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// Drive a Toggle to `on`, tolerating the SwiftUI Form hazard where a centre
    /// `.tap()` lands on the label rather than the switch.
    ///
    /// The retry fires ONLY when the state is readable AND still wrong. That guard
    /// matters: `isToggledOn` is nil for an element exposing no readable state, and
    /// `nil != on` is true, so an unguarded retry would tap a second time on a toggle
    /// that had ALREADY flipped — turning it straight back off and failing the very
    /// assertion it was meant to satisfy. One tap and stop is correct when the state
    /// can't be seen.
    func setToggled(_ on: Bool) {
        guard isToggledOn != on else { return }
        tap()
        if let state = isToggledOn, state != on {
            coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// The element's visible text, wherever the platform put it. A SwiftUI `Text`
    /// exposes its string through `label` on iOS; on macOS a wrapped/multi-line one can
    /// expose it through `value` instead with `label` coming back empty. Concatenating
    /// both is correct everywhere and avoids having to know which case a given row is.
    var visibleText: String {
        let v = (value as? String) ?? ""
        return v.isEmpty ? label : label + "\n" + v
    }

    /// Open this element's `contextMenu`. macOS opens it on a RIGHT-CLICK; a long press
    /// does not produce one there. iOS/iPadOS use the long press.
    func openContextMenu() {
        #if os(macOS)
        rightClick()
        #else
        press(forDuration: 1.0)
        #endif
    }

    /// Tap the element's CENTER via a coordinate. On iPad/macOS, XCUITest's plain
    /// `.tap()` on a small `.buttonStyle(.plain)` control can resolve as hittable yet
    /// never fire the action — a coordinate tap on the same point reliably does.
    func tapCenter() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
