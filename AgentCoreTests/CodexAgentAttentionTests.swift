import Foundation
import XCTest
@testable import ClickyAgentCore

final class CodexAgentAttentionTests: XCTestCase {
    func testWaitingForInputCreatesCompanionAttentionRequest() {
        let request = CodexAgentUserInputRequest(
            requestID: .integer(41),
            threadID: "thread_input",
            turnID: "turn_input",
            itemID: "item_input",
            questions: [
                CodexAgentUserInputQuestion(
                    id: "direction",
                    header: "Direction",
                    question: "Which direction should I use?",
                    isOther: false,
                    isSecret: false,
                    options: nil
                )
            ],
            autoResolutionMs: nil
        )
        let snapshot = makeSnapshot(
            status: .waitingForInput,
            pendingUserInputs: [request]
        )

        XCTAssertEqual(
            snapshot.pendingAttentionRequest,
            CodexAgentAttentionRequest(
                threadID: "thread_input",
                requestID: .integer(41),
                kind: .userInput,
                message: "Which direction should I use?"
            )
        )
        XCTAssertEqual(
            snapshot.pendingAttentionRequest?.spokenAnnouncement,
            "The agent needs your attention."
        )
    }

    func testWaitingForApprovalCreatesCompanionAttentionRequest() {
        let approval = CodexAgentApproval(
            requestID: .string("approval_1"),
            method: "item/commandExecution/requestApproval",
            threadID: "thread_input",
            turnID: "turn_input",
            itemID: "item_push",
            summary: "Publish the branch",
            reason: nil,
            workingDirectory: "/tmp",
            requestedPermissions: nil
        )
        let snapshot = makeSnapshot(
            status: .waitingForApproval,
            pendingApprovals: [approval]
        )

        XCTAssertEqual(
            snapshot.pendingAttentionRequest,
            CodexAgentAttentionRequest(
                threadID: "thread_input",
                requestID: .string("approval_1"),
                kind: .approval,
                message: "Build the site needs approval: Publish the branch"
            )
        )
        XCTAssertEqual(
            snapshot.pendingAttentionRequest?.spokenAnnouncement,
            "The agent needs your attention."
        )
    }

    func testRunningTaskDoesNotCreateCompanionAttentionRequest() {
        XCTAssertNil(makeSnapshot(status: .running).pendingAttentionRequest)
    }

    private func makeSnapshot(
        status: CodexAgentTaskStatus,
        pendingApprovals: [CodexAgentApproval] = [],
        pendingUserInputs: [CodexAgentUserInputRequest] = []
    ) -> CodexAgentTaskSnapshot {
        CodexAgentTaskSnapshot(
            threadID: "thread_input",
            turnID: "turn_input",
            workspacePath: "/tmp",
            title: "Build the site",
            status: status,
            latestAgentMessage: "",
            currentActivity: nil,
            activities: [],
            pendingApprovals: pendingApprovals,
            pendingUserInputs: pendingUserInputs,
            errorMessage: nil,
            lastEventSequence: 1
        )
    }
}
