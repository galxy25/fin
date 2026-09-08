import XCTest
@testable import FinAgentCore

/// `MemoryRedactor`'s masks are pattern-based, not content-aware — a real gotcha this
/// pins after it broke `read_session`'s resolver live: the long-base64/hex mask
/// (`[A-Za-z0-9+/]{40,}={0,2}`) matches an ordinary Unix path exactly as happily as it
/// matches a secret, since `/` and letters are both in that character class. A cwd 40+
/// characters wide is not a rare length. This is why `Daemon.runFixedSessionCommand`
/// takes `redact: false` for `list-windows -a`'s output: that text is STRUCTURAL
/// METADATA to parse (session/window names, working directories), not pane content
/// to scrub, and this file exists so nobody "fixes" that call site back to the default
/// without knowing why it broke.
final class MemoryRedactorTests: XCTestCase {

    /// The exact live failure: a real project path, long enough to trip the mask,
    /// silently loses its directory name — which is precisely the signal
    /// `TmuxSessionResolution.candidates` matches a bare name against.
    func testALongOrdinaryPathIsFalsePositivelyRedacted() {
        let path = "/Users/deepspacenine/forges/levi/africanintellect"
        XCTAssertGreaterThanOrEqual(path.count, 40, "the fixture must actually trip the 40-char mask")
        XCTAssertEqual(MemoryRedactor.redact(path), "[redacted]")
    }

    /// The same class of path, just short enough to survive — which is exactly why this
    /// bug was intermittent rather than a clean, always-reproducing failure: "fin"
    /// resolved fine (a 37-character cwd) while "pocketdj" and "africanintellect"
    /// (41 and 51) silently broke.
    func testAShorterOrdinaryPathSurvivesUnredacted() {
        let path = "/Users/deepspacenine/forges/levi/fin"
        XCTAssertLessThan(path.count, 40, "the fixture must actually stay under the mask's threshold")
        XCTAssertEqual(MemoryRedactor.redact(path), path)
    }

    /// A `tmux list-windows -a` row shaped exactly like `TmuxSessionResolution`'s format
    /// string — confirms redaction corrupts the SPECIFIC field the resolver depends on,
    /// not just a standalone path.
    func testRedactionCorruptsAWindowListingRow() {
        let row = "main\t0\t2.1.235\t/Users/deepspacenine/forges/levi/pocketdj\t0"
        let redacted = MemoryRedactor.redact(row)
        XCTAssertTrue(redacted.contains("[redacted]"))
        XCTAssertFalse(redacted.contains("pocketdj"))
    }
}
