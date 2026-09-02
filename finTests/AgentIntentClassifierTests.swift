import XCTest
@testable import fin

/// Model-free coverage for the deterministic pre-classification `AgentRuntime` uses to
/// force `read_terminal`/`send_input` before ever asking the model. Cheap and fast — no
/// live session or model required — so regressions in the regexes show up immediately
/// instead of only during the slow live-model sweep.
final class AgentIntentClassifierTests: XCTestCase {

    // MARK: - read_terminal positives

    func testClassifiesReadTerminalPhrasings() {
        let phrasings = [
            "What did that print?",
            "what was just echoed?",
            "Did it print anything?",
            "is it done yet?",
            "Is that finished?",
            "did it finish?",
            "has this completed?",
            "What's the output?",
            "what was the result?",
            "Show me the terminal",
            "show the output please",
            "What does the terminal say?",
            "what did the screen show?",
        ]
        for phrasing in phrasings {
            XCTAssertEqual(
                AgentIntentClassifier.classify(phrasing), .readTerminal,
                "expected .readTerminal for: \(phrasing)"
            )
        }
    }

    // MARK: - send_input positives

    func testClassifiesSendInputPhrasings() {
        let cases: [(String, String)] = [
            ("run git status", "git status"),
            ("Run git status", "git status"),
            ("please run git status", "git status"),
            ("could you run git status", "git status"),
            ("can you type pwd", "pwd"),
            ("would you run ls -la", "ls -la"),
            ("type pwd and hit enter", "pwd"),
            ("run `ls -la`", "ls -la"),
            ("execute \"echo hi\"", "echo hi"),
            ("run ls, then press enter", "ls"),
            ("Run this exact shell command in the terminal right now: echo hi", "echo hi"),
        ]
        for (message, expectedCommand) in cases {
            XCTAssertEqual(
                AgentIntentClassifier.classify(message), .sendInput(command: expectedCommand),
                "expected .sendInput(\(expectedCommand)) for: \(message)"
            )
        }
    }

    // MARK: - Adversarial / negative cases

    func testPlainFactualQuestionsAreAmbiguous() {
        let plain = [
            "What is 2 + 2?",
            "What's the capital of France?",
            "How do I reverse a string in Python?",
        ]
        for message in plain {
            XCTAssertEqual(AgentIntentClassifier.classify(message), .ambiguous, "expected .ambiguous for: \(message)")
        }
    }

    func testQuestionAboutRunningADestructiveCommandIsAmbiguousNotADirective() {
        XCTAssertEqual(
            AgentIntentClassifier.classify("should I run rm -rf?"),
            .ambiguous
        )
        XCTAssertEqual(
            AgentIntentClassifier.classify("what happens if I type exit"),
            .ambiguous
        )
    }

    func testQuestionsAboutCommandMechanicsAreAmbiguous() {
        XCTAssertEqual(
            AgentIntentClassifier.classify("why does printf need a newline"),
            .ambiguous
        )
        XCTAssertEqual(
            AgentIntentClassifier.classify("why would someone run rm -rf in production?"),
            .ambiguous
        )
    }

    func testMidSentenceMentionOfRunningIsNotADirective() {
        XCTAssertEqual(
            AgentIntentClassifier.classify("I ran this earlier and it broke everything"),
            .ambiguous
        )
        XCTAssertEqual(
            AgentIntentClassifier.classify("Yesterday you told me to run the tests"),
            .ambiguous
        )
    }

    // MARK: - Imperatives naming the agent's own tools

    /// Live misfire (2026-08): this directive was force-classified send_input and the
    /// agent TYPED it into the terminal instead of calling recall (it self-corrected
    /// a turn later). An imperative whose direct object is one of the agent's own
    /// tools must defer to the model, never force terminal input.
    func testImperativeNamingOwnToolIsAmbiguousNotTyped() {
        let phrasings = [
            "Run recall one more time with the same query.", // the live string
            "run recall with the query wrapper verification",
            "Run remember to keep that fact",
            "execute request_input asking which branch to use",
            "run request input to ask the user about the deploy",
            "Run monitor stop",
            "type recall",
        ]
        for message in phrasings {
            XCTAssertEqual(
                AgentIntentClassifier.classify(message), .ambiguous,
                "expected .ambiguous (model picks the tool) for: \(message)"
            )
        }
    }

    /// Shell tasks stay forced send_input — including ones that merely mention a
    /// tool word mid-command or lead with one that isn't at a word boundary.
    func testShellTasksMentioningToolWordsStillForceSendInput() {
        let cases: [(String, String)] = [
            ("Run git status", "git status"),
            ("run the recall script in bin/", "the recall script in bin/"),
            ("run recall/refresh.sh", "recall/refresh.sh"),
            ("run monitor.sh", "monitor.sh"),
            ("run recall-data-export", "recall-data-export"),
            ("run htop", "htop"),
        ]
        for (message, expectedCommand) in cases {
            XCTAssertEqual(
                AgentIntentClassifier.classify(message), .sendInput(command: expectedCommand),
                "expected .sendInput(\(expectedCommand)) for: \(message)"
            )
        }
    }

    func testEmptyOrWhitespaceIsAmbiguous() {
        XCTAssertEqual(AgentIntentClassifier.classify(""), .ambiguous)
        XCTAssertEqual(AgentIntentClassifier.classify("   "), .ambiguous)
    }

    func testBlankCommandAfterStrippingIsAmbiguousNeverSentAsInput() {
        XCTAssertEqual(AgentIntentClassifier.classify("run"), .ambiguous)
        XCTAssertEqual(AgentIntentClassifier.classify("run ?"), .ambiguous)
    }

    /// The heartbeat prompt mentions read_terminal and sending input, but it must reach
    /// the model's own tool loop — a forced pre-classified call would defeat the check.
    @MainActor
    func testHeartbeatPromptStaysAmbiguous() {
        XCTAssertEqual(AgentIntentClassifier.classify(AgentRuntime.heartbeatPrompt), .ambiguous)
    }
}
