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

    func testRoutesExplicitAgentFollowUp() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Hey, Clicky, continue agent: only touch the parser",
                agentConversationContext: .selected
            ),
            .agentFollowUp(prompt: "only touch the parser")
        )
    }

    func testRoutesNaturalConstraintAndNextStepToExistingAgent() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Only touch the parser.",
                agentConversationContext: .soleRunning
            ),
            .agentFollowUp(prompt: "Only touch the parser.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Now add a regression test.",
                agentConversationContext: .selected
            ),
            .agentFollowUp(prompt: "Now add a regression test.")
        )
    }

    func testDoesNotTreatFollowUpLanguageAsAgentWorkWithoutAgentContext() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Only show the selected paragraph."),
            .companion
        )
    }

    func testRoutesOnlyHighConfidenceMultiStepWorkToNewAgent() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Fix this error, run the tests, and prepare a PR."
            ),
            .agent(prompt: "Fix this error, run the tests, and prepare a PR.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Research the official Codex docs and build a website."
            ),
            .agent(prompt: "Research the official Codex docs and build a website.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Research 25 niche creators and create a CSV."
            ),
            .agent(prompt: "Research 25 niche creators and create a CSV.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Upload this folder, give me the link, then open it."
            ),
            .agent(prompt: "Upload this folder, give me the link, then open it.")
        )
    }

    func testSelectedAgentAcceptsNaturalImperativeRefinement() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Make the background red and more retro.",
                agentConversationContext: .selected
            ),
            .agentFollowUp(prompt: "Make the background red and more retro.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Can you change the heading to blue?",
                agentConversationContext: .selected
            ),
            .agentFollowUp(prompt: "Can you change the heading to blue?")
        )
    }

    func testAgentStatusAndExplicitNegativeRemainCompanionRequests() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Are my agents done yet?"),
            .agentStatus
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Do not start an agent; just explain this error."
            ),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Hey Clicky, agent: inspect this and just explain the risks."
            ),
            .agent(prompt: "inspect this and just explain the risks.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "agent: inspect this and just explain the risks."
            ),
            .agent(prompt: "inspect this and just explain the risks.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Hey Clicky, agent: do not start an agent; just explain this."
            ),
            .companion
        )
    }

    func testRoutesDemonstratedWebsiteLanguageToAgent() {
        XCTAssertEqual(
            SpokenIntentRouter.route("Make a website about the research."),
            .agent(prompt: "Make a website about the research.")
        )
    }

    func testTeachingQuestionDoesNotBecomeAutomaticAgentWork() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Can you explain how to build a website and create an app?"
            ),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Can you tell me how to build a website and create an app?"
            ),
            .companion
        )
    }

    func testHighConfidenceNewWorkOutranksAmbiguousFollowUpContext() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Make a website and create a report.",
                agentConversationContext: .ambiguous
            ),
            .agent(prompt: "Make a website and create a report.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Only change the spacing.",
                agentConversationContext: .ambiguous
            ),
            .agentFollowUp(prompt: "Only change the spacing.")
        )
    }

    func testContractedHardNoAgentRequestStaysWithCompanion() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Don't start an agent — run the tests and prepare a PR yourself."
            ),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route("Don't use an agent, just explain this."),
            .companion
        )
    }

    func testHighConfidenceNewWorkOutranksSelectedAndSoleRunningFollowUpContext() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Make a website about the research.",
                agentConversationContext: .selected
            ),
            .agent(prompt: "Make a website about the research.")
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Make a website about the research.",
                agentConversationContext: .soleRunning
            ),
            .agent(prompt: "Make a website about the research.")
        )
    }

    func testTellAgentWakePhraseRoutesFollowUp() {
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Hey Clicky, tell agent: only touch the parser",
                agentConversationContext: .selected
            ),
            .agentFollowUp(prompt: "only touch the parser")
        )
    }

    func testKeepsQuestionsAndFocusedWritingOutOfAutomaticAgentLane() {
        XCTAssertEqual(
            SpokenIntentRouter.route("What does this error mean?"),
            .companion
        )
        XCTAssertEqual(
            SpokenIntentRouter.route(
                "Write a concise email reply.",
                hasScreenAwareDestination: true
            ),
            .screenAwareComposition
        )
    }
}

final class SpokenAgentFollowUpTargetResolverTests: XCTestCase {
    func testSelectedTaskWinsEvenWhenSeveralAgentsRun() {
        XCTAssertEqual(
            SpokenAgentFollowUpTargetResolver.resolve(
                selectedThreadID: "selected",
                runningThreadIDs: ["first", "second"]
            ),
            .target(threadID: "selected")
        )
    }

    func testSoleRunningTaskIsSafeImplicitTarget() {
        XCTAssertEqual(
            SpokenAgentFollowUpTargetResolver.resolve(
                selectedThreadID: nil,
                runningThreadIDs: ["only"]
            ),
            .target(threadID: "only")
        )
    }

    func testMultipleRunningTasksRequireSelection() {
        XCTAssertEqual(
            SpokenAgentFollowUpTargetResolver.resolve(
                selectedThreadID: nil,
                runningThreadIDs: ["first", "second"]
            ),
            .requiresSelection
        )
    }

    func testNoTaskReportsMissingTarget() {
        XCTAssertEqual(
            SpokenAgentFollowUpTargetResolver.resolve(
                selectedThreadID: nil,
                runningThreadIDs: []
            ),
            .missing
        )
    }
}
