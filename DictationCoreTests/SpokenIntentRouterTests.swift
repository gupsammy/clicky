import XCTest
@testable import ClickyDictationCore

final class SpokenIntentRouterTests: XCTestCase {
    func testRoutesExplicitAgentPrefixToAgentPrompt() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent: inspect this error, but don't edit yet."),
            .agent(prompt: "inspect this error, but don't edit yet.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("agent: run the tests"),
            .agent(prompt: "run the tests")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky agent inspect the parser"),
            .agent(prompt: "inspect the parser")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey, Clicky, agent: run the tests"),
            .agent(prompt: "run the tests")
        )
    }

    func testAgentTriggerIsCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertEqual(
            SpokenIntentRouter.route("  HEY CLICKY AGENT:   prepare a PR  "),
            .agent(prompt: "prepare a PR")
        )
    }

    func testIncompleteAgentTriggerDoesNotReachCompanionLane() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent:   "),
            .invalidAgentTrigger
        )
    }

    func testOrdinarySpeechRemainsInCompanionLane() {
        XCTAssertEqual(
            SpokenIntentRouter.route("What does this error mean?"),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Agent Smith is in this movie."),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky agency status"),
            .companion
        )
    }

    func testWordInternalPunctuationAfterTriggerWordStaysInCompanionLane() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent's not working"),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent-based reasoning is neat"),
            .companion
        )
    }

    func testPhraseSeparatorAfterTriggerWordStillRoutesToAgent() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent, open the readme"),
            .agent(prompt: "open the readme")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Hey Clicky, agent."),
            .invalidAgentTrigger
        )
    }

    func testBareAgentPrefixTrimsLeadingSeparatorsLikeTheWakePhrasePath() {
        XCTAssertEqual(
            SpokenIntentRouter.route("agent: , clean up the code"),
            .agent(prompt: "clean up the code")
        )
    }

    func testFocusedDestinationUsesScreenAwareComposition() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Write a concise reply.",
                hasScreenAwareDestination: true
            ),
            .screenAwareComposition
        )
    }

    func testExplicitAgentTriggerTakesPriorityOverFocusedDestination() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Hey Clicky, agent: inspect the repository",
                hasScreenAwareDestination: true
            ),
            .agent(prompt: "inspect the repository")
        )
    }
}
