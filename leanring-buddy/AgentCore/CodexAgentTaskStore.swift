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
        var activitiesByID: [String: CodexAgentActivity]
        var activityOrder: [String]
        var currentActivityID: String?
        var approvalsByRequestID: [CodexAppServerRequestID: CodexAgentApproval]
        var approvalOrder: [CodexAppServerRequestID]
        var errorMessage: String?
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
                errorMessage: errorMessage,
                lastEventSequence: lastEventSequence
            )
        }
    }

    private let snapshotContinuation: AsyncStream<[CodexAgentTaskSnapshot]>.Continuation
    private var taskStatesByThreadID: [String: MutableTaskState] = [:]
    private var resolvedServerRequestIDs: Set<CodexAppServerRequestID> = []
    private var nextEventSequence: Int64 = 1
    private var notificationMonitoringTask: Task<Void, Never>?
    private var serverRequestMonitoringTask: Task<Void, Never>?

    init() {
        let snapshotStreamPair = AsyncStream<[CodexAgentTaskSnapshot]>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        snapshots = snapshotStreamPair.stream
        snapshotContinuation = snapshotStreamPair.continuation
    }

    deinit {
        notificationMonitoringTask?.cancel()
        serverRequestMonitoringTask?.cancel()
        snapshotContinuation.finish()
    }

    func startMonitoring(client: CodexAppServerClient) {
        stopMonitoring()

        notificationMonitoringTask = Task { [weak self] in
            for await notification in client.notifications {
                guard !Task.isCancelled else { return }
                await self?.apply(notification: notification)
            }
        }

        serverRequestMonitoringTask = Task { [weak self] in
            for await serverRequest in client.serverRequests {
                guard !Task.isCancelled else { return }
                await self?.apply(serverRequest: serverRequest)
            }
        }
    }

    func stopMonitoring() {
        notificationMonitoringTask?.cancel()
        serverRequestMonitoringTask?.cancel()
        notificationMonitoringTask = nil
        serverRequestMonitoringTask = nil
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
        taskState.status = taskStatus(fromThreadStatus: thread.status)
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[thread.id] = taskState
        publishSnapshots()
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

    func apply(serverRequest: CodexAppServerRequest) {
        guard !resolvedServerRequestIDs.contains(serverRequest.id),
              Self.approvalRequestMethods.contains(serverRequest.method),
              let parameters = serverRequest.params?.objectValue,
              let threadID = parameters["threadId"]?.stringValue,
              let turnID = parameters["turnId"]?.stringValue,
              let itemID = parameters["itemId"]?.stringValue else {
            return
        }

        let reason = parameters["reason"]?.stringValue
        let workingDirectory = parameters["cwd"]?.stringValue
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
            workingDirectory: workingDirectory
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
        taskState.status = .waitingForApproval
        if taskState.approvalsByRequestID[serverRequest.id] == nil {
            taskState.approvalOrder.append(serverRequest.id)
        }
        taskState.approvalsByRequestID[serverRequest.id] = approval
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
        publishSnapshots()
    }

    func resolveApproval(requestID: CodexAppServerRequestID) {
        resolvedServerRequestIDs.insert(requestID)
        guard let threadID = taskStatesByThreadID.first(where: { _, taskState in
            taskState.approvalsByRequestID[requestID] != nil
        })?.key,
        var taskState = taskStatesByThreadID[threadID] else {
            return
        }

        taskState.approvalsByRequestID.removeValue(forKey: requestID)
        taskState.approvalOrder.removeAll { $0 == requestID }
        if taskState.status == .waitingForApproval,
           taskState.approvalOrder.isEmpty {
            taskState.status = .running
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[threadID] = taskState
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

        resolvedServerRequestIDs.insert(parameters.requestId)
        guard var taskState = taskStatesByThreadID[parameters.threadId],
              taskState.approvalsByRequestID.removeValue(
                forKey: parameters.requestId
              ) != nil else {
            return
        }

        taskState.approvalOrder.removeAll {
            $0 == parameters.requestId
        }
        if taskState.status == .waitingForApproval,
           taskState.approvalOrder.isEmpty {
            taskState.status = .running
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
    }

    func remove(threadID: String) {
        guard taskStatesByThreadID.removeValue(forKey: threadID) != nil else {
            return
        }
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
        if taskState.turnID != parameters.turn.id {
            taskState.latestAgentMessage = ""
            taskState.activitiesByID.removeAll()
            taskState.activityOrder.removeAll()
            taskState.currentActivityID = nil
            taskState.approvalsByRequestID.removeAll()
            taskState.approvalOrder.removeAll()
        }
        taskState.turnID = parameters.turn.id
        taskState.status = activeStatus(for: taskState)
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
        taskState.status = taskStatus(fromTurnStatus: parameters.turn.status)
        taskState.errorMessage = parameters.turn.error?.message
        finalizeRunningActivities(
            in: &taskState,
            turnStatus: parameters.turn.status
        )
        taskState.currentActivityID = nil
        taskState.approvalsByRequestID.removeAll()
        taskState.approvalOrder.removeAll()
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
        taskState.turnID = parameters.turnId
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
        ),
        let activity = makeActivity(
            from: parameters.item,
            defaultStatus: .completed
        ) else {
            return
        }

        var taskState = taskStatesByThreadID[parameters.threadId] ?? makeEmptyTaskState(
            threadID: parameters.threadId
        )
        taskState.turnID = parameters.turnId
        storeActivity(activity, in: &taskState)
        if taskState.currentActivityID == activity.itemID {
            taskState.currentActivityID = nil
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
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
        if !taskState.status.isTerminal {
            let streamedStatus = taskStatus(fromThreadStatus: parameters.status)
            if streamedStatus.isTerminal {
                resolvedServerRequestIDs.formUnion(taskState.approvalOrder)
                taskState.approvalsByRequestID.removeAll()
                taskState.approvalOrder.removeAll()
                taskState.status = streamedStatus
            } else {
                taskState.status = taskState.approvalOrder.isEmpty
                    ? streamedStatus
                    : .waitingForApproval
            }
        }
        taskState.lastEventSequence = takeNextEventSequence()
        taskStatesByThreadID[parameters.threadId] = taskState
        publishSnapshots()
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
            activitiesByID: [:],
            activityOrder: [],
            currentActivityID: nil,
            approvalsByRequestID: [:],
            approvalOrder: [],
            errorMessage: nil,
            lastEventSequence: 0
        )
    }

    private func taskStatus(fromThreadStatus threadStatus: CodexThreadStatus) -> CodexAgentTaskStatus {
        if threadStatus.activeFlags?.contains("waitingOnApproval") == true {
            return .waitingForApproval
        }
        if threadStatus.activeFlags?.contains("waitingOnUserInput") == true {
            return .waitingForInput
        }

        switch threadStatus.type {
        case "active":
            return .running
        case "systemError":
            return .failed
        default:
            return .queued
        }
    }

    private func taskStatus(fromTurnStatus turnStatus: CodexTurnStatus) -> CodexAgentTaskStatus {
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
        taskState.approvalOrder.isEmpty ? .running : .waitingForApproval
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
