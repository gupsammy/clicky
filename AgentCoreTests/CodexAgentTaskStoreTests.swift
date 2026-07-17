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
        XCTAssertEqual(snapshots[0].status, .idle)
    }

    func testIdleStatusDoesNotCompleteActiveTurnBeforeTurnCompleted() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_idle_order", preview: "Ordering")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_active", status: .inProgress)
                )
            )
        )

        await store.apply(
            notification: try notification(
                method: "thread/status/changed",
                parameters: CodexAgentThreadStatusChangedNotification(
                    threadId: thread.id,
                    status: CodexThreadStatus(type: "idle", activeFlags: nil)
                )
            )
        )

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .running)

        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_active", status: .completed)
                )
            )
        )

        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
    }

    func testTurnStartResponseProjectsRunningStateWithoutNotifications() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_pending", preview: "Pending")
        await store.registerPendingThread(thread: thread, title: "Pending")

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .queued)
        XCTAssertNil(snapshot.turnID)

        await store.registerStartedTurn(
            threadID: thread.id,
            turn: makeTurn(id: "turn_started_response", status: .inProgress)
        )

        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.turnID, "turn_started_response")
    }

    func testTurnStartResponseCannotResurrectSameTurnAfterCompletionNotification() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_fast_completion", preview: "Fast")
        await store.registerPendingThread(thread: thread, title: "Fast")
        let completedTurn = makeTurn(id: "turn_fast", status: .completed)

        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: completedTurn
                )
            )
        )
        await store.registerStartedTurn(
            threadID: thread.id,
            turn: makeTurn(id: completedTurn.id, status: .inProgress)
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.turnID, completedTurn.id)
    }

    func testTurnStartResponseCannotHideSameTurnUserInputNotification() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_fast_input", preview: "Input")
        await store.registerPendingThread(thread: thread, title: "Input")

        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(45),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: thread.id,
                    turnID: "turn_fast_input",
                    itemID: "input_fast",
                    autoResolutionMs: nil
                )
            )
        )
        await store.registerStartedTurn(
            threadID: thread.id,
            turn: makeTurn(id: "turn_fast_input", status: .inProgress)
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .waitingForInput)
        XCTAssertEqual(snapshot.pendingUserInputs.map(\.requestID), [.integer(45)])
    }

    func testFailedTurnStartMakesPendingThreadDismissibleInsteadOfLeavingItQueued() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_failed_start", preview: "Failed start")
        await store.registerPendingThread(thread: thread, title: "Failed start")

        await store.failPendingThread(
            threadID: thread.id,
            error: CodexAppServerError.protocolFailure(
                code: -32000,
                message: "Turn could not start"
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertNil(snapshot.turnID)
        XCTAssertEqual(snapshot.errorMessage, "Turn could not start")
    }

    func testStaleHistoryHydrationCannotOverwriteNewerActiveTurn() async throws {
        let store = CodexAgentTaskStore()
        let completedTurn = makeTurn(id: "turn_old", status: .completed)
        let storedThread = makeThread(
            id: "thread_hydration_race",
            preview: "Hydration race",
            turns: [completedTurn]
        )
        await store.register(thread: storedThread)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: storedThread.id,
                    turn: makeTurn(id: "turn_new", status: .inProgress)
                )
            )
        )

        await store.register(thread: storedThread)

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.turnID, "turn_new")
        XCTAssertEqual(snapshot.status, .running)
    }

    func testSameTurnHydrationCannotOverwriteNewerStreamedMessage() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_same_turn_hydration", preview: "Hydration")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_active", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_active",
                    itemId: "message_live",
                    delta: "New streamed update"
                )
            )
        )

        let staleTurn = CodexTurn(
            id: "turn_active",
            status: .inProgress,
            items: [
                .object([
                    "id": .string("message_live"),
                    "type": .string("agentMessage"),
                    "text": .string("Older persisted update")
                ])
            ],
            startedAt: 1,
            completedAt: nil,
            durationMs: nil,
            error: nil
        )
        await store.register(
            thread: makeThread(
                id: thread.id,
                preview: thread.preview,
                turns: [staleTurn]
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "New streamed update")
        XCTAssertEqual(snapshot.status, .running)
    }

    func testAgentMessageDeltasCoalescePresentationSnapshots() async throws {
        let store = CodexAgentTaskStore()
        let recorder = AgentSnapshotPublicationRecorder()
        let recordingTask = Task {
            for await snapshots in store.snapshots {
                guard !Task.isCancelled else { return }
                await recorder.record(snapshots)
            }
        }
        defer { recordingTask.cancel() }

        let thread = makeThread(
            id: "thread_coalesced_message",
            preview: "Coalesced message"
        )
        await store.register(thread: thread)
        for _ in 0..<100 where await recorder.publicationCount() == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let initialPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(initialPublicationCount, 1)

        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(
                        id: "turn_coalesced_message",
                        status: .inProgress
                    )
                )
            )
        )
        for _ in 0..<100 where await recorder.publicationCount() < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let runningPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(runningPublicationCount, 2)

        for deltaIndex in 0..<20 {
            await store.apply(
                notification: try notification(
                    method: "item/agentMessage/delta",
                    parameters: CodexAgentMessageDeltaNotification(
                        threadId: thread.id,
                        turnId: "turn_coalesced_message",
                        itemId: "message_coalesced",
                        delta: "\(deltaIndex),"
                    )
                )
            )
        }

        try await Task.sleep(for: .milliseconds(10))
        let earlyPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(earlyPublicationCount, 2)

        try await Task.sleep(for: .milliseconds(70))
        let coalescedPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(coalescedPublicationCount, 3)
        let latestSnapshots = await recorder.latestSnapshots()
        let latestSnapshot = try XCTUnwrap(latestSnapshots.first)
        XCTAssertEqual(
            latestSnapshot.latestAgentMessage,
            (0..<20).map { "\($0)," }.joined()
        )

        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_coalesced_message",
                    itemId: "message_coalesced",
                    delta: "urgent"
                )
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(77),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: thread.id,
                    turnID: "turn_coalesced_message",
                    itemID: "input_coalesced",
                    autoResolutionMs: nil
                )
            )
        )

        try await Task.sleep(for: .milliseconds(10))
        let immediateRequestPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(immediateRequestPublicationCount, 4)
        let requestSnapshots = await recorder.latestSnapshots()
        let requestSnapshot = try XCTUnwrap(requestSnapshots.first)
        XCTAssertEqual(requestSnapshot.status, .waitingForInput)
        XCTAssertEqual(requestSnapshot.pendingUserInputs.map(\.requestID), [.integer(77)])
        XCTAssertTrue(requestSnapshot.latestAgentMessage.hasSuffix("urgent"))

        try await Task.sleep(for: .milliseconds(70))
        let finalPublicationCount = await recorder.publicationCount()
        XCTAssertEqual(finalPublicationCount, 4)
    }

    func testCompactionOnlyLatestTurnHydratesThePreviousAgentAnswer() async throws {
        let store = CodexAgentTaskStore()
        let answeredTurn = CodexTurn(
            id: "turn_answered",
            status: .completed,
            items: [
                .object([
                    "id": .string("message_answer"),
                    "type": .string("agentMessage"),
                    "text": .string("Keep this result visible")
                ])
            ],
            startedAt: 1,
            completedAt: 2,
            durationMs: 1_000,
            error: nil
        )
        let compactionTurn = CodexTurn(
            id: "turn_compaction",
            status: .completed,
            items: [
                .object([
                    "id": .string("compaction_1"),
                    "type": .string("contextCompaction"),
                    "status": .string("completed")
                ])
            ],
            startedAt: 3,
            completedAt: 4,
            durationMs: 1_000,
            error: nil
        )
        await store.register(
            thread: makeThread(
                id: "thread_compacted_history",
                preview: "Compacted history",
                turns: [answeredTurn, compactionTurn]
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "Keep this result visible")
        XCTAssertEqual(snapshot.activities.map(\.kind), [.contextCompaction])
    }

    func testContextCompactionPreservesPriorAnswerAndUsesTypedActivity() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_compaction", preview: "Compaction")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_answer", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_answer",
                    itemId: "message_answer",
                    delta: "Prior final answer"
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_answer", status: .completed)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_compaction", status: .inProgress)
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/started",
                parameters: CodexAgentItemStartedNotification(
                    threadId: thread.id,
                    turnId: "turn_compaction",
                    item: .object([
                        "id": .string("compaction_1"),
                        "type": .string("contextCompaction"),
                        "status": .string("inProgress")
                    ]),
                    startedAtMs: 3
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "Prior final answer")
        XCTAssertEqual(snapshot.currentActivity?.kind, .contextCompaction)
        XCTAssertEqual(snapshot.currentActivity?.summary, "Compacting context")
    }

    func testRegisterHydratesCompletedHistoryMessageAndFileActivity() async throws {
        let store = CodexAgentTaskStore()
        let completedTurn = CodexTurn(
            id: "turn_completed",
            status: .completed,
            items: [
                .object([
                    "id": .string("file_1"),
                    "type": .string("fileChange"),
                    "status": .string("completed"),
                    "changes": .array([
                        .object(["path": .string("Sources/AgentHUD.swift")])
                    ])
                ]),
                .object([
                    "id": .string("message_1"),
                    "type": .string("agentMessage"),
                    "text": .string("The agent HUD is ready for review.")
                ])
            ],
            startedAt: 1,
            completedAt: 2,
            durationMs: 1_000,
            error: nil
        )
        let thread = makeThread(
            id: "thread_history",
            preview: "Build the HUD",
            turns: [completedTurn]
        )

        await store.register(thread: thread)

        let snapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.turnID, completedTurn.id)
        XCTAssertEqual(snapshot.latestAgentMessage, "The agent HUD is ready for review.")
        XCTAssertEqual(snapshot.activities.first?.kind, .fileChange)
        XCTAssertEqual(snapshot.activities.first?.summary, "Sources/AgentHUD.swift")
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

    func testServerResolutionClearsAndTombstonesTheApprovalRequest() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_resolved", preview: "Resolved")
        await store.register(thread: thread)
        let approvalRequest = CodexAppServerRequest(
            id: .string("approval_resolved"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string(thread.id),
                "turnId": .string("turn_resolved"),
                "itemId": .string("command_resolved"),
                "command": .string("swift test")
            ])
        )

        await store.apply(serverRequest: approvalRequest)
        await store.apply(
            notification: try notification(
                method: "serverRequest/resolved",
                parameters: CodexAgentServerRequestResolvedNotification(
                    requestId: approvalRequest.id,
                    threadId: thread.id
                )
            )
        )

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)

        await store.apply(serverRequest: approvalRequest)
        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
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

    func testSystemErrorOverridesAndTombstonesPendingApproval() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Failing task")
        await store.register(thread: thread)

        let approvalRequest = CodexAppServerRequest(
            id: .integer(27),
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
                method: "thread/status/changed",
                parameters: CodexAgentThreadStatusChangedNotification(
                    threadId: thread.id,
                    status: CodexThreadStatus(
                        type: "systemError",
                        activeFlags: nil
                    )
                )
            )
        )
        await store.apply(serverRequest: approvalRequest)

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)
    }

    func testPermissionApprovalRetainsRequestedPermissionProfile() async throws {
        let store = CodexAgentTaskStore()
        let requestedPermissions: CodexJSONValue = .object([
            "network": .object(["enabled": .boolean(true)]),
            "fileSystem": .null
        ])

        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(22),
                method: "item/permissions/requestApproval",
                params: .object([
                    "threadId": .string("thread_permissions"),
                    "turnId": .string("turn_permissions"),
                    "itemId": .string("item_permissions"),
                    "permissions": requestedPermissions
                ])
            )
        )

        let snapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(
            snapshot.pendingApprovals.first?.requestedPermissions,
            requestedPermissions
        )
    }

    func testStructuredUserInputRequestRemainsBoundToItsJSONRPCRequest() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_user_input", preview: "Needs a choice")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_user_input", status: .inProgress)
                )
            )
        )

        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(41),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(thread.id),
                    "turnId": .string("turn_user_input"),
                    "itemId": .string("user_input_1"),
                    "questions": .array([
                        .object([
                            "id": .string("direction"),
                            "header": .string("Layout"),
                            "question": .string("Which direction should I use?"),
                            "isOther": .boolean(true),
                            "isSecret": .boolean(false),
                            "options": .array([
                                .object([
                                    "label": .string("Protocol console"),
                                    "description": .string("Show the JSON-RPC lifecycle.")
                                ]),
                                .object([
                                    "label": .string("Architecture map"),
                                    "description": .string("Lead with components.")
                                ])
                            ])
                        ])
                    ]),
                    "autoResolutionMs": .null
                ])
            )
        )

        var currentSnapshots = await store.currentSnapshots()
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .waitingForInput)
        XCTAssertEqual(snapshot.pendingUserInputs.first?.requestID, .integer(41))
        XCTAssertEqual(snapshot.pendingUserInputs.first?.questions.first?.id, "direction")
        XCTAssertNil(snapshot.pendingUserInputs.first?.autoResolutionMs)

        await store.resolveUserInput(requestID: .integer(41))
        currentSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertTrue(snapshot.pendingUserInputs.isEmpty)
    }

    func testServerRequestResolvedClearsTheExactPendingCard() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_resolved_request", preview: "Resolved")
        await store.register(thread: thread)
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .string("input_resolved"),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: thread.id,
                    turnID: "turn_resolved",
                    itemID: "input_item",
                    autoResolutionMs: 60_000
                )
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .string("approval_still_pending"),
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string(thread.id),
                    "turnId": .string("turn_resolved"),
                    "itemId": .string("command_pending"),
                    "command": .string("swift test")
                ])
            )
        )

        await store.apply(
            notification: try notification(
                method: "serverRequest/resolved",
                parameters: CodexAgentServerRequestResolvedNotification(
                    requestId: .string("input_resolved"),
                    threadId: thread.id
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertTrue(snapshot.pendingUserInputs.isEmpty)
        XCTAssertEqual(
            snapshot.pendingApprovals.map(\.requestID),
            [.string("approval_still_pending")]
        )
        XCTAssertEqual(snapshot.status, .waitingForApproval)
    }

    func testResolvedNotificationBeforeRequestPreventsLateCardFromAppearing() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_early_resolution", preview: "Resolved early")

        await store.apply(
            notification: try notification(
                method: "serverRequest/resolved",
                parameters: CodexAgentServerRequestResolvedNotification(
                    requestId: .string("resolved_before_delivery"),
                    threadId: thread.id
                )
            )
        )
        await store.register(thread: thread)
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .string("resolved_before_delivery"),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: thread.id,
                    turnID: "turn_early_resolution",
                    itemID: "input_early_resolution",
                    autoResolutionMs: 60_000
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertTrue(snapshot.pendingUserInputs.isEmpty)
        XCTAssertEqual(snapshot.status, .idle)
    }

    func testManualUserInputResolutionClaimsRequestBeforeResponse() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_manual_input", preview: "Manual input")
        await store.register(thread: thread)
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(72),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: thread.id,
                    turnID: "turn_manual_input",
                    itemID: "input_manual",
                    autoResolutionMs: nil
                )
            )
        )

        let firstClaimSucceeded = await store.beginManualUserInputResolution(
            requestID: .integer(72)
        )
        let duplicateClaimSucceeded = await store.beginManualUserInputResolution(
            requestID: .integer(72)
        )
        XCTAssertTrue(firstClaimSucceeded)
        XCTAssertFalse(duplicateClaimSucceeded)

        await store.resolveUserInput(requestID: .integer(72))
        let currentSnapshots = await store.currentSnapshots()
        XCTAssertTrue(currentSnapshots.first?.pendingUserInputs.isEmpty == true)
    }

    func testRemovingAThreadPrunesItsResolvedRequestDedupeMemory() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_pruned_dedupe", preview: "Pruned")
        await store.register(thread: thread)

        let userInputRequest = CodexAppServerRequest(
            id: .string("input_pruned"),
            method: "item/tool/requestUserInput",
            params: userInputParameters(
                threadID: thread.id,
                turnID: "turn_pruned",
                itemID: "input_item_pruned",
                autoResolutionMs: nil
            )
        )
        await store.apply(serverRequest: userInputRequest)
        await store.resolveUserInput(requestID: .string("input_pruned"))

        // While the thread exists, a duplicate delivery must stay deduplicated.
        await store.apply(serverRequest: userInputRequest)
        let snapshotsWhileThreadExists = await store.currentSnapshots()
        XCTAssertTrue(
            snapshotsWhileThreadExists.first?.pendingUserInputs.isEmpty == true
        )

        await store.remove(threadID: thread.id)

        // Once the thread is removed its dedupe memory must go with it: the
        // same request ID delivered for a fresh registration of the thread
        // surfaces again instead of being dropped by leaked resolved state.
        await store.register(thread: thread)
        await store.apply(serverRequest: userInputRequest)
        let snapshotsAfterThreadRemoval = await store.currentSnapshots()
        let snapshotAfterThreadRemoval = try XCTUnwrap(snapshotsAfterThreadRemoval.first)
        XCTAssertEqual(
            snapshotAfterThreadRemoval.pendingUserInputs.map(\.requestID),
            [.string("input_pruned")]
        )
    }

    func testConnectionFailureMakesActiveTasksDurablyRecoverable() async throws {
        let store = CodexAgentTaskStore()
        let activeThread = makeThread(id: "thread_disconnected", preview: "Active")
        let completedThread = makeThread(
            id: "thread_already_complete",
            preview: "Complete",
            turns: [makeTurn(id: "turn_complete", status: .completed)]
        )
        await store.register(thread: activeThread)
        await store.register(thread: completedThread)
        await store.apply(
            notification: try notification(
                method: "item/started",
                parameters: CodexAgentItemStartedNotification(
                    threadId: activeThread.id,
                    turnId: "turn_disconnected",
                    item: commandItem(
                        id: "command_disconnected",
                        command: "long-running command",
                        status: "inProgress"
                    ),
                    startedAtMs: 1
                )
            )
        )
        await store.apply(
            serverRequest: CodexAppServerRequest(
                id: .integer(73),
                method: "item/tool/requestUserInput",
                params: userInputParameters(
                    threadID: activeThread.id,
                    turnID: "turn_disconnected",
                    itemID: "input_disconnected",
                    autoResolutionMs: nil
                )
            )
        )

        await store.failActiveTasks(
            error: CodexAppServerError.processTerminated(
                exitCode: 9,
                standardError: "terminated for test"
            )
        )

        let snapshots = await store.currentSnapshots()
        let failedSnapshot = try XCTUnwrap(
            snapshots.first { $0.threadID == activeThread.id }
        )
        let completedSnapshot = try XCTUnwrap(
            snapshots.first { $0.threadID == completedThread.id }
        )
        XCTAssertEqual(failedSnapshot.status, .failed)
        XCTAssertEqual(
            failedSnapshot.errorMessage,
            "Codex app-server stopped unexpectedly (status 9)."
        )
        XCTAssertEqual(failedSnapshot.activities.first?.status, .failed)
        XCTAssertTrue(failedSnapshot.pendingUserInputs.isEmpty)
        XCTAssertEqual(completedSnapshot.status, .completed)
        XCTAssertNil(completedSnapshot.errorMessage)
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

    func testNewAgentMessageItemReplacesPriorUpdateInsteadOfInterleavingDeltas() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_message_items", preview: "Message items")
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
                    itemId: "message_update_1",
                    delta: "First progress update"
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_update_2",
                    delta: "Second update"
                )
            )
        )
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_update_2",
                    delta: " continues"
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "Second update continues")
    }

    func testCompletedAgentMessageReplacesPartialStreamWithAuthoritativeText() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_final_message", preview: "Final message")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "Duplicated part part"
                )
            )
        )

        await store.apply(
            notification: try notification(
                method: "item/completed",
                parameters: CodexAgentItemCompletedNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    item: agentMessageItem(
                        id: "message_1",
                        text: "Authoritative final text"
                    ),
                    completedAtMs: 2
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "Authoritative final text")
    }

    func testTurnCompletedReconcilesFinalMessageWhenItemCompletionWasMissed() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_turn_message", preview: "Turn message")
        await store.register(thread: thread)
        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_1",
                    itemId: "message_1",
                    delta: "Partial"
                )
            )
        )

        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(
                        id: "turn_1",
                        status: .completed,
                        items: [
                            agentMessageItem(
                                id: "message_1",
                                text: "Complete from turn"
                            )
                        ]
                    )
                )
            )
        )

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.latestAgentMessage, "Complete from turn")
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
        var snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.turnID, "turn_2")
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.latestAgentMessage, "First answer")
        XCTAssertTrue(snapshot.activities.isEmpty)
        XCTAssertTrue(snapshot.pendingApprovals.isEmpty)

        await store.apply(
            notification: try notification(
                method: "item/agentMessage/delta",
                parameters: CodexAgentMessageDeltaNotification(
                    threadId: thread.id,
                    turnId: "turn_2",
                    itemId: "message_2",
                    delta: "Second answer"
                )
            )
        )

        let updatedSnapshots = await store.currentSnapshots()
        snapshot = try XCTUnwrap(updatedSnapshots.first)
        XCTAssertEqual(snapshot.latestAgentMessage, "Second answer")
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

    func testStaleApprovalForACompletedTurnCannotRollBackTheNextTurn() async throws {
        let store = CodexAgentTaskStore()
        let thread = makeThread(id: "thread_1", preview: "Stale approval replay")
        await store.register(thread: thread)

        let firstTurnApprovalRequest = CodexAppServerRequest(
            id: .integer(88),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string(thread.id),
                "turnId": .string("turn_1"),
                "itemId": .string("command_1"),
                "command": .string("swift build")
            ])
        )

        await store.apply(
            notification: try notification(
                method: "turn/started",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .inProgress)
                )
            )
        )
        await store.apply(serverRequest: firstTurnApprovalRequest)
        await store.resolveApproval(requestID: firstTurnApprovalRequest.id)
        await store.apply(
            notification: try notification(
                method: "turn/completed",
                parameters: CodexTurnLifecycleNotification(
                    threadId: thread.id,
                    turn: makeTurn(id: "turn_1", status: .completed)
                )
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

        // A duplicate delivery of turn 1's already-resolved approval arrives
        // while turn 2 is actively running.
        await store.apply(serverRequest: firstTurnApprovalRequest)

        let currentSnapshots = await store.currentSnapshots()
        let snapshot = try XCTUnwrap(currentSnapshots.first)
        XCTAssertEqual(snapshot.turnID, "turn_2")
        XCTAssertEqual(snapshot.status, .running)
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

    private func makeThread(
        id: String,
        preview: String,
        turns: [CodexTurn] = []
    ) -> CodexThread {
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
            turns: turns
        )
    }

    private func makeTurn(
        id: String,
        status: CodexTurnStatus,
        items: [CodexJSONValue] = [],
        errorMessage: String? = nil
    ) -> CodexTurn {
        CodexTurn(
            id: id,
            status: status,
            items: items,
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

    private func agentMessageItem(
        id: String,
        text: String
    ) -> CodexJSONValue {
        .object([
            "id": .string(id),
            "type": .string("agentMessage"),
            "text": .string(text)
        ])
    }

    private func userInputParameters(
        threadID: String,
        turnID: String,
        itemID: String,
        autoResolutionMs: Int?
    ) -> CodexJSONValue {
        .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "itemId": .string(itemID),
            "questions": .array([
                .object([
                    "id": .string("direction"),
                    "header": .string("Layout"),
                    "question": .string("Which direction should I use?"),
                    "isOther": .boolean(false),
                    "isSecret": .boolean(false),
                    "options": .array([
                        .object([
                            "label": .string("Architecture map"),
                            "description": .string("Lead with components.")
                        ])
                    ])
                ])
            ]),
            "autoResolutionMs": autoResolutionMs.map {
                CodexJSONValue.integer(Int64($0))
            } ?? .null
        ])
    }
}

private actor AgentSnapshotPublicationRecorder {
    private var recordedSnapshots: [[CodexAgentTaskSnapshot]] = []

    func record(_ snapshots: [CodexAgentTaskSnapshot]) {
        recordedSnapshots.append(snapshots)
    }

    func publicationCount() -> Int {
        recordedSnapshots.count
    }

    func latestSnapshots() -> [CodexAgentTaskSnapshot] {
        recordedSnapshots.last ?? []
    }
}
