import XCTest
@testable import fin

/// Exercises the exact mechanism behind the control strip's keyboard-toggle button.
/// Doesn't need a real SSH connection — the bug (and the fix) both live entirely in
/// UIResponder/first-responder handling, so a real UIWindow + the terminal view is
/// enough to test it directly, deterministically, without a device/interactive pass.
@MainActor
final class KeyboardVisibilityTests: XCTestCase {
    func testHideKeyboardActuallyResignsFirstResponder() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            XCTFail("No connected UIWindowScene to attach a test window to")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let session = TerminalSession(serverID: UUID())
        window.addSubview(session.terminalView)
        session.terminalView.frame = window.bounds

        session.showKeyboard()
        XCTAssertTrue(
            session.terminalView.isFirstResponder,
            "Precondition failed: showKeyboard() should make the terminal view first responder"
        )
        XCTAssertTrue(
            session.isKeyboardVisible,
            "Precondition failed: isKeyboardVisible should track becomeFirstResponder"
        )

        session.hideKeyboard()
        XCTAssertFalse(
            session.terminalView.isFirstResponder,
            "hideKeyboard() did not resign first responder — the keyboard would stay up"
        )
        XCTAssertFalse(
            session.isKeyboardVisible,
            "isKeyboardVisible did not update after hideKeyboard()"
        )
    }

    /// Regression guard for the real bug: popover/sheet dismissal in UIKit restores
    /// whatever was first responder before presentation as a side effect. Calling
    /// hideKeyboard() before dismissing (rather than after, in .onDisappear) gets
    /// silently undone by that — this is why the fix defers the call.
    func testHideKeyboardAfterDismissalCompletes() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            XCTFail("No connected UIWindowScene to attach a test window to")
            return
        }
        let window = UIWindow(windowScene: scene)
        let rootVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let session = TerminalSession(serverID: UUID())
        rootVC.view.addSubview(session.terminalView)
        session.terminalView.frame = window.bounds

        session.showKeyboard()
        XCTAssertTrue(session.terminalView.isFirstResponder, "Precondition: keyboard should be up")

        let popoverVC = UIViewController()
        popoverVC.modalPresentationStyle = .popover
        popoverVC.popoverPresentationController?.sourceView = rootVC.view
        popoverVC.popoverPresentationController?.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let presentExpectation = expectation(description: "popover presented")
        rootVC.present(popoverVC, animated: false) { presentExpectation.fulfill() }
        wait(for: [presentExpectation], timeout: 2)

        // Dismiss FIRST, then hide the keyboard once dismissal has actually completed.
        let dismissExpectation = expectation(description: "popover dismissed")
        popoverVC.dismiss(animated: false) {
            session.hideKeyboard()
            dismissExpectation.fulfill()
        }
        wait(for: [dismissExpectation], timeout: 2)

        XCTAssertFalse(
            session.terminalView.isFirstResponder,
            "Keyboard should be hidden when hideKeyboard() runs after dismissal completes"
        )
        XCTAssertFalse(session.isKeyboardVisible)
    }
}
