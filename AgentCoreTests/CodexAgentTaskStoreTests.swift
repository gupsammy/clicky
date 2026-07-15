import Foundation
import XCTest
@testable import ClickyAgentCore

final class CodexAgentTaskStoreTests: XCTestCase {
    func testRegisterPublishesNewestTaskFirst() async {
        let store = CodexAgentTaskStore()

        await store.register(
            thread: makeThread(id: "thread_1", preview: "First task")
        )
        await store.register(
            thread: makeThread(id: "thread_2", preview: "Second task")
        )

        let snapshots = await store.currentSnapshots()
        XCTAssertEqual(snapshots.map(\.threadID), ["thread_2", "thread_1"])
        XCTAssertEqual(snapshots[0].title, "Second task")
        XCTAssertEqual(snapshots[0].status, .queued)
    }

    func testTurnEventsAssembleMessageActivityAndApprovalState() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Inspect the repo")
        await store.register(thread: thread)

        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "I found "
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "the issue."
                )
            )
        )

        let runningCommandItem = commandItem(
            id: "command_1",
            command: "swift test",
            status: "inProgress"
        )
        await store.apply(
            notification: try notification(
                method: "item/started",
                parameters: CodexAgentItemStartedNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    item: runningCommandItem,
                    startedAtMs: 1
                )
            )
        )

        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(91),
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string(thread.id),
                    "turnId": .string("turn_1"),
                    "itemId": .string("command_1"),
                    "command": .string("swift test"),
                    "cwd": .string(thread.cwd),
                    "reason": .string("Run the test suite")
                ])
            )
        )

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .waitingForApproval)
        XCTAssertEqual(snapshot.latestAgentMessage, "I found the issue.")
        XCTAssertEqual(snapshot.currentActivity?.summary, "swift test")
        XCTAssertEqual(snapshot.pendingApprovals.first?.requestID, .integer(91))
        XCTAssertEqual(snapshot.pendingApprovals.first?.reason, "Run the test suite")

        await store.resolveApproval(requestID: .integer(91))
        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)

        await store.apply(
            notification: try notification(
                method: "item/completed",
                parameters: CodexAgentItemCompletedNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    item: commandItem(
                        id: "command_1",
                        command: "swift test",
                        status: "completed"
                    ),
                    completedAtMs: 2
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .completed)
                )
            )
        )

        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertNil(snapshot.currentActivity)
        XCTAssertEqual(snapshot.activities.first?.status, .completed)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)
    }

    func testThreadStatusTracksWaitingForInput() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Waiting task")
        await store.register(thread: thread)

        await store.apply(
            notification: try notification(
                method: "thread/status/changed",
                parameters: CodexAgentThreadStatusChangedNotification(
                    threadId: thread.id,
                    status: CodexThreadStatus(
                        type: "active",
                        activeFlags: ["waitingOnUserInput"]
                    )
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .waitingForInput)
    }

    func testConcurrentThreadsKeepMessagesAndStatusesIsolated() async throws {
        let store = CodexAgentTaskStore()
        let firstThread = makeThread(id: "thread_1", preview: "First")
        let secondThread = makeThread(id: "thread_2", preview: "Second")
        await store.register(thread: firstThread)
        await store.register(thread: secondThread)

        for thread in [firstThread, secondThread] {
            await store.apply(
                notification: try notification(
                    method: "turn/started",
                    parameters: CodexTurnLifecycleNotification(
                        threadId: thread.id,
                        turn: makeTurn(
                            id: "turn_\(thread.id)",
                            status: .inProgress
                        )
                    )
                )
            )
            await store.apply(
                notification: try notification(
                    method: "item/agentMessage/delta",
                    parameters: CodexAgentMessageDeltaNotification(
                        threadId: thread.id,
                        turnId: "turn_\(thread.id)",
                        itemId: "message_\(thread.id)",
                        delta: "Message for \(thread.id)"
                    )
                )
            )
        }

        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: firstThread.id,
                    turn: makeTurn(
                        id: "turn_\(firstThread.id)",
                        status: .completed
                    )
                )
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .string("approval_2"),
                method: "item/fileChange/requestApproval",
                params: .object([
                    "threadId": .string(secondThread.id),
                    "turnId": .string("turn_\(secondThread.id)"),
                    "itemId": .string("file_2"),
                    "reason": .string("Write outside the Agent Folder")
                ])
            )
        )

        let snapshots = await store.currentSnapshots()
        let firstSnapshot = try XCTUnwrap(
            snapshots.first { $0.threadID == firstThread.id }
        )
        let secondSnapshot = try XCTUnwrap(
            snapshots.first { $0.threadID == secondThread.id }
        )

        XCTAssertEqual(firstSnapshot.status, .completed)
        XCTAssertEqual(firstSnapshot.latestAgentMessage, "Message for thread_1")
        XCTAssertEqual(secondSnapshot.status, .waitingForApproval)
        XCTAssertEqual(secondSnapshot.latestAgentMessage, "Message for thread_2")
        XCTAssertEqual(secondSnapshot.pendingApprovals.count, 1)
    }

    func testActivityHistoryIsBoundedToMostRecentHundredItems() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Long task")
        await store.register(thread: thread)

        for activityIndex in 0..<105 {
            await store.apply(
                notification: try notification(
                    method: "item/started",
                    parameters: CodexAgentItemStartedNotification(
                        threadId: thread.id,
                        turnId: "turn_1",
                        item: commandItem(
                            id: "command_\(activityIndex)",
                            command: "command \(activityIndex)",
                            status: "inProgress"
                        ),
                        startedAtMs: Int64(activityIndex)
                    )
                )
            )
        }

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.activities.count, 100)
        XCTAssertEqual(snapshot.activities.first?.itemID, "command_5")
        XCTAssertEqual(snapshot.activities.last?.itemID, "command_104")
    }

    func testNewTurnResetsPerTurnMessageActivityAndApprovalState() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Multi-turn task")
        await store.register(thread: thread)

        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "First answer"
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/started",
                parameters: CodexAgentItemStartedNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    item: commandItem(
                        id: "command_1",
                        command: "swift test",
                        status: "inProgress"
                    ),
                    startedAtMs: 1
                )
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(1),
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string(thread.id),
                    "turnId": .string("turn_1"),
                    "itemId": .string("command_1"),
                    "command": .string("swift test")
                ])
            )
        )

        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_2", status: .inProgress)
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.turnID, "turn_2")
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertTrue(snapshot.latestAgentMessage.isEmpty)
        XCTAssertTrue(snapshot.activities.isEmpty)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)
    }

    func testInterruptedTurnMarksUnfinishedActivityFailed() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Interrupted task")
        await store.register(thread: thread)

        await store.apply(
            notification: try notification(
                method: "item/started",
                parameters: CodexAgentItemStartedNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    item: commandItem(
                        id: "command_1",
                        command: "long-running command",
                        status: "inProgress"
                    ),
                    startedAtMs: 1
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .interrupted)
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .interrupted)
        XCTAssertEqual(snapshot.activities.first?.status, .failed)
        XCTAssertNil(snapshot.currentActivity)
    }

    func testOutOfOrderStreamsCannotHideOrResurrectApprovalState() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Approval ordering")
        await store.register(thread: thread)

        let approvalRequest = CodexAppServerRequest(
            id: .integer(77),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string(thread.id),
                "turnId": .string("turn_1"),
                "itemId": .string("command_1"),
                "command": .string("swift test")
            ])
        )
        await store.apply(serverRequest: approvalRequest)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "Waiting for approval"
                )
            )
        )

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .waitingForApproval)
        XCTAssertEqual(snapshot.pendingApprovals.count, 1)

        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .completed)
                )
            )
        )
        await store.apply(serverRequest: approvalRequest)

        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)
    }

    func testMalformedAndUnknownEventsDoNotCreateTasks() async {
        let store = CodexAgentTaskStore()

        await store.apply(
            notification: CodexAppServerNotification(
                method: "item/agentMessage/delta",
                params: .object(["delta": .string("missing identifiers")])
            )
        )
        await store.apply(
            notification: CodexAppServerNotification(
                method: "future/notification",
                params: .object([:])
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(1),
                method: "attestation/generate",
                params: .object([:])
            )
        )

        let snapshots = await store.currentSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    private func notification<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) throws -> CodexAppServerNotification {
        let encodedParameters = try JSONEncoder().encode(parameters)
        let dynamicParameters = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: encodedParameters
        )
        return CodexAppServerNotification(
            method: method,
            params: dynamicParameters
        )
    }

    private func makeThread(id: String, preview: String) -> CodexThread {
        CodexThread(
            id: id,
            sessionId: "session_\(id)",
            preview: preview,
            name: nil,
            cwd: "/tmp/clicky-workspace",
            modelProvider: "openai",
            cliVersion: "0.144.2",
            createdAt: 1,
            updatedAt: 2,
            ephemeral: false,
            status: CodexThreadStatus(type: "idle", activeFlags: nil),
            turns: []
        )
    }

    private func makeTurn(
        id: String,
        status: CodexTurnStatus,
        errorMessage: String? = nil
    ) -> CodexTurn {
        CodexTurn(
            id: id,
            status: status,
            items: [],
            startedAt: 1,
            completedAt: status == .inProgress ? nil : 2,
            durationMs: status == .inProgress ? nil : 1_000,
            error: errorMessage.map {
                CodexTurnError(
                    message: $0,
                    additionalDetails: nil,
                    codexErrorInfo: nil
                )
            }
        )
    }

    private func commandItem(
        id: String,
        command: String,
        status: String
    ) -> CodexJSONValue {
        .object([
            "id": .string(id),
            "type": .string("commandExecution"),
            "command": .string(command),
            "status": .string(status)
        ])
    }
}
