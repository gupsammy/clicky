//
//  CodexAgentTaskStore.swift
//  leanring-buddy
//
//  Reduces streamed app-server events into concurrent, HUD-ready task snapshots.
//

import Foundation

actor CodexAgentTaskStore {
    nonisolated let snapshots: AsyncStream<[CodexAgentTaskSnapshot]>

    private static let maximumActivitiesPerTask = 100
    private static let approvalRequestMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval"
    ]

    private struct MutableTaskState {
        let threadID: String
        var turnID: String?
        // Turn IDs that have already reached turn/completed on this thread.
        // Used to reject stale or duplicate approval deliveries for finished
        // turns without blocking legitimate early approvals for a new turn.
        var completedTurnIDs: Set<String>
        var workspacePath: String
        var title: String
        var status: CodexAgentTaskStatus
        var latestAgentMessage: String
        var latestAgentMessageItemID: String?
        var activitiesByID: [String: CodexAgentActivity]
        var activityOrder: [String]
        var currentActivityID: String?
        var approvalsByRequestID: [CodexAppServerRequestID: CodexAgentApproval]
        var approvalOrder: [CodexAppServerRequestID]
        var userInputsByRequestID: [CodexAppServerRequestID: CodexAgentUserInputRequest]
        var userInputOrder: [CodexAppServerRequestID]
        var errorMessage: String?
        var hasActiveTurn: Bool
        var shouldResetAgentMessageOnNextDelta: Bool
        var lastEventSequence: Int64

        var snapshot: CodexAgentTaskSnapshot {
            CodexAgentTaskSnapshot(
                threadID: threadID,
                turnID: turnID,
                workspacePath: workspacePath,
                title: title,
                status: status,
                latestAgentMessage: latestAgentMessage,
                currentActivity: currentActivityID.flatMap { activitiesByID[$0] },
                activities: activityOrder.compactMap { activitiesByID[$0] },
                pendingApprovals: approvalOrder.compactMap { approvalsByRequestID[$0] },
                pendingUserInputs: userInputOrder.compactMap { userInputsByRequestID[$0] },
                errorMessage: errorMessage,
                lastEventSequence: lastEventSequence
            )
        }
    }

    private let snapshotContinuation: AsyncStream<[CodexAgentTaskSnapshot]>.Continuation
    private var taskStatesByThreadID: [String: MutableTaskState] = [:]
    private var nextEventSequence: Int64 = 1
    private var notificationMonitoringTask: Task<Void, Never>?
    private var serverRequestMonitoringTask: Task<Void, Never>?
    private var automaticUserInputResolutionTasks: [
        CodexAppServerRequestID: Task<Void, Never>
    ] = [:]
    // Resolved request IDs are remembered per thread so remove(threadID:) can
    // prune them when the thread goes away; a single flat set would grow for
    // the lifetime of the actor. Resolutions whose thread can no longer be
    // determined land in the unknown-thread set, which only resets when a new
    // monitoring session starts.
    private var resolvedServerRequestIDsByThreadID: [
        String: Set<CodexAppServerRequestID>
    ] = [:]
    private var resolvedServerRequestIDsWithUnknownThread: Set<CodexAppServerRequestID> = []
    private var userInputRequestIDsBeingResolved: Set<CodexAppServerRequestID> = []

    init() {
        let snapshotStreamPair = AsyncStream<[CodexAgentTaskSnapshot]>.makeStream(
            // Every emission is a complete state snapshot, so keeping older
            // snapshots only makes UI consumers replay stale intermediate state.
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshots = snapshotStreamPair.stream
        snapshotContinuation = snapshotStreamPair.continuation
    }

    deinit {
        notificationMonitoringTask?.cancel()
        serverRequestMonitoringTask?.cancel()
        for automaticResolutionTask in automaticUserInputResolutionTasks.values {
            automaticResolutionTask.cancel()
        }
        snapshotContinuation.finish()
    }

    func startMonitoring(client: CodexAppServerClient) {
        stopMonitoring()
        resolvedServerRequestIDsByThreadID.removeAll()
        resolvedServerRequestIDsWithUnknownThread.removeAll()
        userInputRequestIDsBeingResolved.removeAll()

        notificationMonitoringTask = Task { [weak self] in
            for await notification in client.notifications {
                guard !Task.isCancelled else { return }
                await self?.apply(notification: notification)
            }
        }

        serverRequestMonitoringTask = Task { [weak self] in
            for await serverRequest in client.serverRequests {
                guard !Task.isCancelled else { return }
                await self?.apply(
                    serverRequest: serverRequest,
                    autoResolutionClient: client
                )
            }
        }
    }

    func stopMonitoring() {
        notificationMonitoringTask?.cancel()
        serverRequestMonitoringTask?.cancel()
        notificationMonitoringTask = nil
        serverRequestMonitoringTask = nil
        cancelAllAutomaticUserInputResolutions()
    }

    func register(thread: CodexThread, title: String? = nil) {
        var taskState = taskStatesByThreadID[thread.id] ?? makeEmptyTaskState(
            threadID: thread.id
        )
        taskState.workspacePath = thread.cwd
        taskState.title = normalizedTitle(
            title ?? thread.name ?? thread.preview,
            fallback: "Agent task"
        )

        // A thread/read hydration can finish after a newer live turn has begun.
        // In that case only merge stable metadata; persisted older turns must not
        // overwrite the authoritative streamed state for the active turn.
        taskState.completedTurnIDs.formUnion(
            thread.turns.compactMap { turn in
                switch turn.status {
                case .completed, .interrupted, .failed:
                    return turn.id
                case .inProgress, .unknown:
                    return nil
                }
            }
        )
        if taskState.hasActiveTurn {
            taskState.lastEventSequence = takeNextEventSequence()
            taskStatesByThreadID[thread.id] = taskState
            publishSnapshots()
            return
        }

        let streamedThreadStatus = taskStatus(from: thread.status)
        if let latestTurn = thread.turns.last {
            if taskState.turnID != latestTurn.id {
                taskState.activitiesByID.removeAll()
                taskState.activityOrder.removeAll()
                taskState.currentActivityID = nil
                taskState.approvalsByRequestID.removeAll()
                taskState.approvalOrder.removeAll()
                taskState.userInputsByRequestID.removeAll()
                taskState.userInputOrder.removeAll()
                taskState.latestAgentMessageItemID = nil
            }
            taskState.turnID = latestTurn.id
            taskState.hasActiveTurn = latestTurn.status == .inProgress
            taskState.shouldResetAgentMessageOnNextDelta = false
            taskState.status = streamedThreadStatus == .running
                ? .running
                : taskStatus(from: latestTurn.status)
            taskState.errorMessage = latestTurn.error?.message
            let latestAgentMessageItem = latestAgentMessageItem(
                in: thread.turns
            )
            taskState.latestAgentMessage = latestAgentMessageItem?
                .objectValue?["text"]?.stringValue ?? taskState.latestAgentMessage
            taskState.latestAgentMessageItemID = latestAgentMessageItem?
                .objectValue?["id"]?.stringValue

            for item in latestTurn.items {
                let defaultActivityStatus: CodexAgentActivityStatus = latestTurn.status == .inProgress
                    ? .running
                    : .completed
                guard let activity = makeActivity(
                    from: item,
                    defaultStatus: defaultActivityStatus
                ) else {
                    continue
                }
                storeActivity(activity, in: &taskState)
            }
        } else {
            taskState.status = streamedThreadStatus
            taskState.hasActiveTurn = false
            taskState.shouldResetAgentMessageOnNextDelta = false
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[thread.id] = taskState
        publishSnapshots()
    }

    func registerPendingThread(thread: CodexThread, title: String) {
        var taskState = taskStatesByThreadID[thread.id] ?? makeEmptyTaskState(
            threadID: thread.id
        )
        taskState.workspacePath = thread.cwd
        taskState.title = normalizedTitle(title, fallback: "Agent task")
        taskState.status = .queued
        taskState.hasActiveTurn = false
        taskState.shouldResetAgentMessageOnNextDelta = false
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[thread.id] = taskState
        publishSnapshots()
    }

    func registerStartedTurn(threadID: String, turn: CodexTurn) {
        var taskState = taskStatesByThreadID[threadID] ?? makeEmptyTaskState(
            threadID: threadID
        )

        // The response to turn/start and the notification stream travel through
        // independent tasks. If a same-turn notification has already arrived,
        // it is newer and may already be terminal or waiting for the user.
        guard taskState.turnID != turn.id else { return }

        resetPerTurnStateIfNeeded(turnID: turn.id, taskState: &taskState)
        taskState.turnID = turn.id
        taskState.status = .running
        taskState.hasActiveTurn = true
        taskState.errorMessage = nil
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    func failPendingThread(threadID: String, error: Error) {
        guard var taskState = taskStatesByThreadID[threadID],
              taskState.turnID == nil else {
            return
        }
        taskState.status = .failed
        taskState.hasActiveTurn = false
        taskState.errorMessage = error.localizedDescription
        taskState.currentActivityID = nil
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    func failActiveTasks(error: Error) {
        var didChangeTask = false

        for threadID in Array(taskStatesByThreadID.keys) {
            guard var taskState = taskStatesByThreadID[threadID],
                  taskState.hasActiveTurn || !taskState.status.isTerminal else {
                continue
            }

            finalizeRunningActivities(in: &taskState, turnStatus: .failed)
            taskState.status = .failed
            taskState.hasActiveTurn = false
            taskState.errorMessage = error.localizedDescription
            taskState.currentActivityID = nil
            taskState.approvalsByRequestID.removeAll()
            taskState.approvalOrder.removeAll()
            cancelAutomaticUserInputResolutions(
                requestIDs: taskState.userInputOrder
            )
            userInputRequestIDsBeingResolved.subtract(taskState.userInputOrder)
            taskState.userInputsByRequestID.removeAll()
            taskState.userInputOrder.removeAll()
            taskState.lastEventSequence = takeNextEventSequence()
            taskStatesByThreadID[threadID] = taskState
            didChangeTask = true
        }

        if didChangeTask {
            publishSnapshots()
        }
    }

    func apply(notification: CodexAppServerNotification) {
        switch notification.method {
        case "turn/started":
            applyTurnStarted(notification)
        case "turn/completed":
            applyTurnCompleted(notification)
        case "item/agentMessage/delta":
            applyAgentMessageDelta(notification)
        case "item/started":
            applyItemStarted(notification)
        case "item/completed":
            applyItemCompleted(notification)
        case "thread/status/changed":
            applyThreadStatusChanged(notification)
        case "serverRequest/resolved":
            applyServerRequestResolved(notification)
        default:
            return
        }
    }

    func apply(
        serverRequest: CodexAppServerRequest,
        autoResolutionClient: CodexAppServerClient? = nil
    ) {
        guard !isServerRequestResolved(serverRequest.id),
              !userInputRequestIDsBeingResolved.contains(serverRequest.id) else {
            return
        }

        if serverRequest.method == "item/tool/requestUserInput" {
            applyUserInputRequest(
                serverRequest,
                autoResolutionClient: autoResolutionClient
            )
            return
        }

        guard Self.approvalRequestMethods.contains(serverRequest.method),
              let parameters = serverRequest.params?.objectValue,
              let threadID = parameters["threadId"]?.stringValue,
              let turnID = parameters["turnId"]?.stringValue,
              let itemID = parameters["itemId"]?.stringValue else {
            return
        }

        let reason = parameters["reason"]?.stringValue
        let workingDirectory = parameters["cwd"]?.stringValue
        let requestedPermissions = parameters["permissions"]
        let approval = CodexAgentApproval(
            requestID: serverRequest.id,
            method: serverRequest.method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            summary: approvalSummary(
                method: serverRequest.method,
                parameters: parameters
            ),
            reason: reason,
            workingDirectory: workingDirectory,
            requestedPermissions: requestedPermissions
        )

        var taskState = taskStatesByThreadID[threadID] ?? makeEmptyTaskState(
            threadID: threadID
        )
        if taskState.status.isTerminal,
           taskState.turnID == turnID {
            return
        }
        // A stale or duplicate approval delivery for an already-completed turn
        // must not roll the task back to that turn or resurrect a resolved
        // approval. Matching on completed turn IDs (rather than "any turn other
        // than the current one") keeps legitimate early approvals — ones that
        // arrive just before their own turn/started — working.
        if taskState.completedTurnIDs.contains(turnID) {
            return
        }
        taskState.turnID = turnID
        taskState.hasActiveTurn = true
        taskState.status = .waitingForApproval
        if taskState.approvalsByRequestID[serverRequest.id] == nil {
            taskState.approvalOrder.append(serverRequest.id)
        }
        taskState.approvalsByRequestID[serverRequest.id] = approval
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    private func applyUserInputRequest(
        _ serverRequest: CodexAppServerRequest,
        autoResolutionClient: CodexAppServerClient?
    ) {
        guard let parametersValue = serverRequest.params,
              let parametersData = try? JSONEncoder().encode(parametersValue),
              let parameters = try? JSONDecoder().decode(
                CodexAgentUserInputParameters.self,
                from: parametersData
              ),
              !parameters.questions.isEmpty else {
            return
        }

        let userInputRequest = CodexAgentUserInputRequest(
            requestID: serverRequest.id,
            threadID: parameters.threadId,
            turnID: parameters.turnId,
            itemID: parameters.itemId,
            questions: parameters.questions,
            autoResolutionMs: parameters.autoResolutionMs
        )
        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        if taskState.status.isTerminal,
           taskState.turnID == parameters.turnId {
            return
        }
        if taskState.completedTurnIDs.contains(parameters.turnId) {
            return
        }
        taskState.turnID = parameters.turnId
        taskState.hasActiveTurn = true
        taskState.status = .waitingForInput
        if taskState.userInputsByRequestID[serverRequest.id] == nil {
            taskState.userInputOrder.append(serverRequest.id)
        }
        taskState.userInputsByRequestID[serverRequest.id] = userInputRequest
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()

        if let autoResolutionMs = parameters.autoResolutionMs,
           let autoResolutionClient {
            scheduleAutomaticUserInputResolution(
                requestID: serverRequest.id,
                afterMilliseconds: autoResolutionMs,
                client: autoResolutionClient
            )
        }
    }

    func resolveApproval(requestID: CodexAppServerRequestID) {
        let threadID = taskStatesByThreadID.first(where: { _, taskState in
            taskState.approvalsByRequestID[requestID] != nil
        })?.key
        markServerRequestResolved(requestID: requestID, threadID: threadID)
        guard let threadID,
              var taskState = taskStatesByThreadID[threadID] else {
            return
        }

        taskState.approvalsByRequestID.removeValue(forKey: requestID)
        taskState.approvalOrder.removeAll { $0 == requestID }
        if taskState.status == .waitingForApproval,
           taskState.approvalOrder.isEmpty {
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    func resolveUserInput(requestID: CodexAppServerRequestID) {
        cancelAutomaticUserInputResolution(requestID: requestID)
        userInputRequestIDsBeingResolved.remove(requestID)
        let threadID = taskStatesByThreadID.first(where: { _, taskState in
            taskState.userInputsByRequestID[requestID] != nil
        })?.key
        markServerRequestResolved(requestID: requestID, threadID: threadID)
        guard let threadID,
              var taskState = taskStatesByThreadID[threadID] else {
            return
        }

        taskState.userInputsByRequestID.removeValue(forKey: requestID)
        taskState.userInputOrder.removeAll { $0 == requestID }
        if taskState.status == .waitingForInput,
           taskState.userInputOrder.isEmpty {
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    func snoozeAutomaticUserInputResolution(
        requestID: CodexAppServerRequestID
    ) {
        cancelAutomaticUserInputResolution(requestID: requestID)
    }

    func beginManualUserInputResolution(
        requestID: CodexAppServerRequestID
    ) -> Bool {
        cancelAutomaticUserInputResolution(requestID: requestID)
        guard isUserInputRequestPending(requestID: requestID),
              !isServerRequestResolved(requestID),
              userInputRequestIDsBeingResolved.insert(requestID).inserted else {
            return false
        }
        return true
    }

    func abandonUserInputResolution(requestID: CodexAppServerRequestID) {
        userInputRequestIDsBeingResolved.remove(requestID)
    }

    private func markServerRequestResolved(
        requestID: CodexAppServerRequestID,
        threadID: String?
    ) {
        if let threadID {
            resolvedServerRequestIDsByThreadID[threadID, default: []]
                .insert(requestID)
        } else {
            resolvedServerRequestIDsWithUnknownThread.insert(requestID)
        }
    }

    private func isServerRequestResolved(
        _ requestID: CodexAppServerRequestID
    ) -> Bool {
        resolvedServerRequestIDsWithUnknownThread.contains(requestID)
            || resolvedServerRequestIDsByThreadID.values.contains { resolvedRequestIDs in
                resolvedRequestIDs.contains(requestID)
            }
    }

    private func scheduleAutomaticUserInputResolution(
        requestID: CodexAppServerRequestID,
        afterMilliseconds autoResolutionMilliseconds: Int,
        client: CodexAppServerClient
    ) {
        cancelAutomaticUserInputResolution(requestID: requestID)

        automaticUserInputResolutionTasks[requestID] = Task { [weak self] in
            guard autoResolutionMilliseconds >= 0 else { return }
            try? await Task.sleep(
                for: .milliseconds(autoResolutionMilliseconds)
            )
            guard !Task.isCancelled,
                  await self?.beginAutomaticUserInputResolution(
                    requestID: requestID
                  ) == true else {
                return
            }

            do {
                try await client.respond(
                    to: requestID,
                    with: CodexAgentUserInputResponse(answers: [:])
                )
                await self?.resolveUserInput(requestID: requestID)
            } catch {
                await self?.abandonUserInputResolution(requestID: requestID)
                await self?.automaticUserInputResolutionDidFail(
                    requestID: requestID
                )
            }
        }
    }

    private func isUserInputRequestPending(
        requestID: CodexAppServerRequestID
    ) -> Bool {
        taskStatesByThreadID.values.contains { taskState in
            taskState.userInputsByRequestID[requestID] != nil
        }
    }

    private func beginAutomaticUserInputResolution(
        requestID: CodexAppServerRequestID
    ) -> Bool {
        guard isUserInputRequestPending(requestID: requestID),
              !isServerRequestResolved(requestID),
              userInputRequestIDsBeingResolved.insert(requestID).inserted else {
            return false
        }
        return true
    }

    private func automaticUserInputResolutionDidFail(
        requestID: CodexAppServerRequestID
    ) {
        automaticUserInputResolutionTasks.removeValue(forKey: requestID)
    }

    private func cancelAutomaticUserInputResolution(
        requestID: CodexAppServerRequestID
    ) {
        automaticUserInputResolutionTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func cancelAutomaticUserInputResolutions(
        requestIDs: [CodexAppServerRequestID]
    ) {
        for requestID in requestIDs {
            cancelAutomaticUserInputResolution(requestID: requestID)
        }
    }

    private func cancelAllAutomaticUserInputResolutions() {
        for automaticResolutionTask in automaticUserInputResolutionTasks.values {
            automaticResolutionTask.cancel()
        }
        automaticUserInputResolutionTasks.removeAll()
    }

    func remove(threadID: String) {
        guard let removedTaskState = taskStatesByThreadID.removeValue(
            forKey: threadID
        ) else {
            return
        }
        cancelAutomaticUserInputResolutions(
            requestIDs: removedTaskState.userInputOrder
        )
        userInputRequestIDsBeingResolved.subtract(removedTaskState.userInputOrder)
        // The server cannot re-deliver requests for a thread that no longer
        // exists, so its resolved-request dedupe memory goes with it.
        resolvedServerRequestIDsByThreadID.removeValue(forKey: threadID)
        publishSnapshots()
    }

    func currentSnapshots() -> [CodexAgentTaskSnapshot] {
        sortedSnapshots()
    }

    private func applyTurnStarted(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexTurnLifecycleNotification.self
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        resetPerTurnStateIfNeeded(
            turnID: parameters.turn.id,
            taskState: &taskState
        )
        taskState.turnID = parameters.turn.id
        taskState.status = activeStatus(for: taskState)
        taskState.hasActiveTurn = true
        taskState.errorMessage = nil
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyTurnCompleted(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexTurnLifecycleNotification.self
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        taskState.turnID = parameters.turn.id
        taskState.completedTurnIDs.insert(parameters.turn.id)
        taskState.status = taskStatus(from: parameters.turn.status)
        taskState.hasActiveTurn = false
        taskState.errorMessage = parameters.turn.error?.message
        if let finalAgentMessageItem = latestAgentMessageItem(
            in: [parameters.turn]
        ),
        let finalAgentMessageObject = finalAgentMessageItem.objectValue,
        let finalAgentMessageText = finalAgentMessageObject["text"]?.stringValue {
            taskState.latestAgentMessage = finalAgentMessageText
            taskState.latestAgentMessageItemID = finalAgentMessageObject["id"]?.stringValue
            taskState.shouldResetAgentMessageOnNextDelta = false
        }
        finalizeRunningActivities(
            in: &taskState,
            turnStatus: parameters.turn.status
        )
        taskState.currentActivityID = nil
        taskState.approvalsByRequestID.removeAll()
        taskState.approvalOrder.removeAll()
        cancelAutomaticUserInputResolutions(
            requestIDs: taskState.userInputOrder
        )
        userInputRequestIDsBeingResolved.subtract(taskState.userInputOrder)
        taskState.userInputsByRequestID.removeAll()
        taskState.userInputOrder.removeAll()
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyAgentMessageDelta(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexAgentMessageDeltaNotification.self
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        if taskState.shouldResetAgentMessageOnNextDelta
            || taskState.latestAgentMessageItemID != parameters.itemId {
            taskState.latestAgentMessage = ""
            taskState.shouldResetAgentMessageOnNextDelta = false
        }
        taskState.turnID = parameters.turnId
        taskState.hasActiveTurn = true
        taskState.latestAgentMessageItemID = parameters.itemId
        taskState.latestAgentMessage.append(parameters.delta)
        if !taskState.status.isTerminal {
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyItemStarted(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexAgentItemStartedNotification.self
        ),
        let activity = makeActivity(
            from: parameters.item,
            defaultStatus: .running
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        taskState.turnID = parameters.turnId
        taskState.hasActiveTurn = true
        storeActivity(activity, in: &taskState)
        taskState.currentActivityID = activity.itemID
        if !taskState.status.isTerminal {
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyItemCompleted(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexAgentItemCompletedNotification.self
        ) else {
            return
        }

        if applyCompletedAgentMessage(parameters) {
            return
        }

        guard let activity = makeActivity(
            from: parameters.item,
            defaultStatus: .completed
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        taskState.turnID = parameters.turnId
        taskState.hasActiveTurn = true
        storeActivity(activity, in: &taskState)
        if taskState.currentActivityID == activity.itemID {
            taskState.currentActivityID = nil
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyCompletedAgentMessage(
        _ parameters: CodexAgentItemCompletedNotification
    ) -> Bool {
        guard let itemObject = parameters.item.objectValue,
              itemObject["type"]?.stringValue == "agentMessage",
              let itemID = itemObject["id"]?.stringValue,
              let finalText = itemObject["text"]?.stringValue else {
            return false
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        taskState.turnID = parameters.turnId
        taskState.latestAgentMessage = finalText
        taskState.latestAgentMessageItemID = itemID
        taskState.shouldResetAgentMessageOnNextDelta = false
        if !taskState.status.isTerminal {
            taskState.hasActiveTurn = true
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
        return true
    }

    private func applyThreadStatusChanged(_ notification: CodexAppServerNotification) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexAgentThreadStatusChangedNotification.self
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        let streamedStatus = taskStatus(from: parameters.status)
        switch streamedStatus {
        case .running, .waitingForApproval, .waitingForInput:
            if taskState.turnID == nil || !taskState.status.isTerminal {
                let locallyDerivedStatus = activeStatus(for: taskState)
                taskState.status = locallyDerivedStatus == .running
                    ? streamedStatus
                    : locallyDerivedStatus
            }
        case .idle:
            // App-server may emit idle before the authoritative turn/completed.
            // Never infer turn success from thread liveness alone.
            if taskState.turnID == nil && !taskState.hasActiveTurn {
                taskState.status = .idle
            }
        case .failed:
            if !taskState.status.isTerminal {
                for requestID in taskState.approvalOrder + taskState.userInputOrder {
                    markServerRequestResolved(
                        requestID: requestID,
                        threadID: parameters.threadId
                    )
                }
                taskState.approvalsByRequestID.removeAll()
                taskState.approvalOrder.removeAll()
                cancelAutomaticUserInputResolutions(
                    requestIDs: taskState.userInputOrder
                )
                userInputRequestIDsBeingResolved.subtract(taskState.userInputOrder)
                taskState.userInputsByRequestID.removeAll()
                taskState.userInputOrder.removeAll()
                taskState.hasActiveTurn = false
                taskState.status = .failed
            }
        case .queued, .completed, .interrupted:
            break
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func applyServerRequestResolved(
        _ notification: CodexAppServerNotification
    ) {
        guard let parameters = try? notification.decodeParameters(
            as: CodexAgentServerRequestResolvedNotification.self
        ) else {
            return
        }

        markServerRequestResolved(
            requestID: parameters.requestId,
            threadID: parameters.threadId
        )
        userInputRequestIDsBeingResolved.remove(parameters.requestId)
        cancelAutomaticUserInputResolution(requestID: parameters.requestId)

        guard var taskState = taskStatesByThreadID[parameters.threadId] else {
            return
        }

        let removedApproval = taskState.approvalsByRequestID.removeValue(
            forKey: parameters.requestId
        ) != nil
        taskState.approvalOrder.removeAll { $0 == parameters.requestId }

        let removedUserInput = taskState.userInputsByRequestID.removeValue(
            forKey: parameters.requestId
        ) != nil
        taskState.userInputOrder.removeAll { $0 == parameters.requestId }
        guard removedApproval || removedUserInput else { return }
        if !taskState.status.isTerminal {
            taskState.status = activeStatus(for: taskState)
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    private func resetPerTurnStateIfNeeded(
        turnID: String,
        taskState: inout MutableTaskState
    ) {
        guard taskState.turnID != turnID else { return }
        taskState.shouldResetAgentMessageOnNextDelta = true
        taskState.activitiesByID.removeAll()
        taskState.activityOrder.removeAll()
        taskState.currentActivityID = nil
        taskState.approvalsByRequestID.removeAll()
        taskState.approvalOrder.removeAll()
        cancelAutomaticUserInputResolutions(
            requestIDs: taskState.userInputOrder
        )
        userInputRequestIDsBeingResolved.subtract(taskState.userInputOrder)
        taskState.userInputsByRequestID.removeAll()
        taskState.userInputOrder.removeAll()
    }

    private func makeEmptyTaskState(threadID: String) -> MutableTaskState {
        MutableTaskState(
            threadID: threadID,
            turnID: nil,
            completedTurnIDs: [],
            workspacePath: "",
            title: "Agent task",
            status: .queued,
            latestAgentMessage: "",
            latestAgentMessageItemID: nil,
            activitiesByID: [:],
            activityOrder: [],
            currentActivityID: nil,
            approvalsByRequestID: [:],
            approvalOrder: [],
            userInputsByRequestID: [:],
            userInputOrder: [],
            errorMessage: nil,
            hasActiveTurn: false,
            shouldResetAgentMessageOnNextDelta: false,
            lastEventSequence: 0
        )
    }

    private func latestAgentMessageItem(
        in turns: [CodexTurn]
    ) -> CodexJSONValue? {
        for turn in turns.reversed() {
            if let agentMessageItem = turn.items.reversed().first(where: { item in
                item.objectValue?["type"]?.stringValue == "agentMessage"
            }) {
                return agentMessageItem
            }
        }
        return nil
    }

    private func taskStatus(from threadStatus: CodexThreadStatus) -> CodexAgentTaskStatus {
        if threadStatus.activeFlags?.contains("waitingOnApproval") == true {
            return .waitingForApproval
        }
        if threadStatus.activeFlags?.contains("waitingOnUserInput") == true {
            return .waitingForInput
        }

        switch threadStatus.type {
        case "active":
            return .running
        case "idle", "notLoaded":
            return .idle
        case "systemError":
            return .failed
        default:
            return .queued
        }
    }

    private func taskStatus(from turnStatus: CodexTurnStatus) -> CodexAgentTaskStatus {
        switch turnStatus {
        case .completed:
            return .completed
        case .interrupted:
            return .interrupted
        case .failed:
            return .failed
        case .inProgress, .unknown:
            return .running
        }
    }

    private func activeStatus(
        for taskState: MutableTaskState
    ) -> CodexAgentTaskStatus {
        if !taskState.approvalOrder.isEmpty {
            return .waitingForApproval
        }
        if !taskState.userInputOrder.isEmpty {
            return .waitingForInput
        }
        return .running
    }

    private func makeActivity(
        from item: CodexJSONValue,
        defaultStatus: CodexAgentActivityStatus
    ) -> CodexAgentActivity? {
        guard let itemObject = item.objectValue,
              let itemID = itemObject["id"]?.stringValue,
              let itemType = itemObject["type"]?.stringValue else {
            return nil
        }

        let kind: CodexAgentActivityKind
        let summary: String

        switch itemType {
        case "commandExecution":
            kind = .command
            summary = itemObject["command"]?.stringValue ?? "Command"
        case "fileChange":
            kind = .fileChange
            summary = fileChangeSummary(itemObject["changes"])
        case "mcpToolCall":
            kind = .mcpTool
            summary = toolSummary(itemObject, fallback: "MCP tool")
        case "dynamicToolCall":
            kind = .dynamicTool
            summary = toolSummary(itemObject, fallback: "Tool")
        case "collabAgentToolCall":
            kind = .collaboration
            summary = itemObject["tool"]?.stringValue ?? "Agent collaboration"
        case "plan":
            kind = .plan
            summary = itemObject["text"]?.stringValue ?? "Plan"
        case "reasoning":
            kind = .reasoning
            summary = "Reasoning"
        case "contextCompaction":
            kind = .contextCompaction
            summary = "Compacting context"
        case "agentMessage", "userMessage":
            return nil
        default:
            kind = .other
            summary = itemType
        }

        return CodexAgentActivity(
            itemID: itemID,
            kind: kind,
            summary: summary,
            status: activityStatus(
                from: itemObject["status"]?.stringValue,
                defaultStatus: defaultStatus
            )
        )
    }

    private func activityStatus(
        from rawStatus: String?,
        defaultStatus: CodexAgentActivityStatus
    ) -> CodexAgentActivityStatus {
        switch rawStatus {
        case "completed":
            return .completed
        case "failed":
            return .failed
        case "declined":
            return .declined
        case "inProgress":
            return .running
        default:
            return defaultStatus
        }
    }

    private func storeActivity(
        _ activity: CodexAgentActivity,
        in taskState: inout MutableTaskState
    ) {
        if taskState.activitiesByID[activity.itemID] == nil {
            taskState.activityOrder.append(activity.itemID)
        }
        taskState.activitiesByID[activity.itemID] = activity

        while taskState.activityOrder.count > Self.maximumActivitiesPerTask {
            let removedActivityID = taskState.activityOrder.removeFirst()
            taskState.activitiesByID.removeValue(forKey: removedActivityID)
        }
    }

    private func finalizeRunningActivities(
        in taskState: inout MutableTaskState,
        turnStatus: CodexTurnStatus
    ) {
        let terminalActivityStatus: CodexAgentActivityStatus = turnStatus == .completed
            ? .completed
            : .failed

        for activityID in taskState.activityOrder {
            guard let activity = taskState.activitiesByID[activityID],
                  activity.status == .running else {
                continue
            }
            taskState.activitiesByID[activityID] = CodexAgentActivity(
                itemID: activity.itemID,
                kind: activity.kind,
                summary: activity.summary,
                status: terminalActivityStatus
            )
        }
    }

    private func fileChangeSummary(_ changesValue: CodexJSONValue?) -> String {
        guard let changes = changesValue?.arrayValue else {
            return "File changes"
        }

        let changedPaths = changes.compactMap { change in
            change.objectValue?["path"]?.stringValue
        }
        if let firstChangedPath = changedPaths.first {
            let additionalChangeCount = changedPaths.count - 1
            if additionalChangeCount > 0 {
                return "\(firstChangedPath) +\(additionalChangeCount) more"
            }
            return firstChangedPath
        }
        return "File changes"
    }

    private func toolSummary(
        _ itemObject: [String: CodexJSONValue],
        fallback: String
    ) -> String {
        let server = itemObject["server"]?.stringValue
        let tool = itemObject["tool"]?.stringValue

        if let server, let tool {
            return "\(server) / \(tool)"
        }
        return tool ?? fallback
    }

    private func approvalSummary(
        method: String,
        parameters: [String: CodexJSONValue]
    ) -> String {
        switch method {
        case "item/commandExecution/requestApproval":
            return parameters["command"]?.stringValue
                ?? parameters["reason"]?.stringValue
                ?? "Command approval"
        case "item/fileChange/requestApproval":
            return parameters["reason"]?.stringValue
                ?? parameters["grantRoot"]?.stringValue
                ?? "File change approval"
        case "item/permissions/requestApproval":
            return parameters["reason"]?.stringValue
                ?? "Permission approval"
        default:
            return "Approval required"
        }
    }

    private func normalizedTitle(_ title: String, fallback: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTitle.isEmpty ? fallback : normalizedTitle
    }

    private func takeNextEventSequence() -> Int64 {
        let eventSequence = nextEventSequence
        nextEventSequence += 1
        return eventSequence
    }

    private func publishSnapshots() {
        snapshotContinuation.yield(sortedSnapshots())
    }

    private func sortedSnapshots() -> [CodexAgentTaskSnapshot] {
        taskStatesByThreadID.values
            .map(\.snapshot)
            .sorted { firstSnapshot, secondSnapshot in
                firstSnapshot.lastEventSequence > secondSnapshot.lastEventSequence
            }
    }
}
