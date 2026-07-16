//
//  CodexAgentCoordinator.swift
//  leanring-buddy
//
//  Owns the single app-server event pipeline and safe task operations used by UI surfaces.
//

import Foundation

enum CodexAgentCoordinatorError: LocalizedError, Equatable, Sendable {
    case workspaceMismatch(expectedPath: String, providedPath: String)

    var errorDescription: String? {
        switch self {
        case .workspaceMismatch(let expectedPath, let providedPath):
            return "This agent belongs to \(expectedPath), not \(providedPath)."
        }
    }
}

actor CodexAgentCoordinator {
    nonisolated let snapshots: AsyncStream<[CodexAgentTaskSnapshot]>
    nonisolated let failures: AsyncStream<CodexAppServerError>
    nonisolated let accountLoginCompletions: AsyncStream<CodexAppServerAccountLoginCompletedNotification>

    private let client: CodexAppServerClient
    private let taskStore: CodexAgentTaskStore
    private var hasStarted = false
    private static let maximumHydratedHistoryThreads = 20

    init(
        client: CodexAppServerClient,
        taskStore: CodexAgentTaskStore = CodexAgentTaskStore()
    ) {
        self.client = client
        self.taskStore = taskStore
        self.snapshots = taskStore.snapshots
        self.failures = client.failures
        self.accountLoginCompletions = client.accountLoginCompletions
    }

    static func makeLive() throws -> CodexAgentCoordinator {
        CodexAgentCoordinator(client: try CodexAppServerClient.makeLive())
    }

    func start() async throws -> CodexAppServerSession {
        guard !hasStarted else {
            throw CodexAppServerError.alreadyConnected
        }

        await taskStore.startMonitoring(client: client)
        do {
            let session = try await client.connect()
            hasStarted = true
            return session
        } catch {
            await taskStore.stopMonitoring()
            throw error
        }
    }

    func stop() async {
        await taskStore.stopMonitoring()
        await client.stop()
        hasStarted = false
    }

    func currentSnapshots() async -> [CodexAgentTaskSnapshot] {
        await taskStore.currentSnapshots()
    }

    func recordConnectionFailure(_ error: Error) async {
        await taskStore.failActiveTasks(error: error)
    }

    func startChatGPTLogin() async throws -> CodexAppServerChatGPTLoginResponse {
        try await client.startChatGPTLogin()
    }

    func refreshAccount() async throws -> CodexAppServerAccountReadResponse {
        try await client.refreshAccount()
    }

    func cancelChatGPTLogin(loginID: String) async throws {
        _ = try await client.cancelChatGPTLogin(loginID: loginID)
    }

    @discardableResult
    func loadHistory(in workspace: CodexAgentWorkspace) async throws -> [CodexThread] {
        let response = try await client.listThreads(in: workspace)
        var hydratedThreadsByID: [String: CodexThread] = [:]

        for listedThread in response.data.prefix(Self.maximumHydratedHistoryThreads) {
            if let detailedThread = try? await client.readThread(
                threadID: listedThread.id,
                in: workspace,
                includeTurns: true
            ).thread {
                hydratedThreadsByID[listedThread.id] = detailedThread
            }
        }

        // thread/list returns newest first. Register oldest first so the store's
        // event ordering preserves that newest-first result for presentation.
        for listedThread in response.data.reversed() {
            await taskStore.register(
                thread: hydratedThreadsByID[listedThread.id] ?? listedThread
            )
        }
        return response.data
    }

    @discardableResult
    func startTask(
        prompt: String,
        in workspace: CodexAgentWorkspace,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) async throws -> String {
        let threadResponse = try await client.startThread(
            in: workspace,
            model: model
        )
        let title = Self.taskTitle(from: prompt)
        await taskStore.registerPendingThread(
            thread: threadResponse.thread,
            title: title
        )

        let turnResponse: CodexTurnStartResponse
        do {
            turnResponse = try await client.startTurn(
                threadID: threadResponse.thread.id,
                prompt: prompt,
                in: workspace,
                model: model,
                reasoningEffort: reasoningEffort
            )
        } catch {
            await taskStore.failPendingThread(
                threadID: threadResponse.thread.id,
                error: error
            )
            throw error
        }
        await taskStore.registerStartedTurn(
            threadID: threadResponse.thread.id,
            turn: turnResponse.turn
        )
        return threadResponse.thread.id
    }

    func followUp(
        prompt: String,
        on task: CodexAgentTaskSnapshot,
        in workspace: CodexAgentWorkspace,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) async throws {
        let currentTask = await taskStore.currentSnapshots().first(
            where: { $0.threadID == task.threadID }
        ) ?? task

        guard currentTask.workspacePath == workspace.path else {
            throw CodexAgentCoordinatorError.workspaceMismatch(
                expectedPath: currentTask.workspacePath,
                providedPath: workspace.path
            )
        }

        if !currentTask.status.isTerminal, let turnID = currentTask.turnID {
            guard !currentTask.activities.contains(where: { activity in
                activity.kind == .contextCompaction
            }) else {
                throw CodexAppServerError.threadBusyCompacting
            }
            _ = try await client.steerTurn(
                threadID: currentTask.threadID,
                expectedTurnID: turnID,
                prompt: prompt
            )
            return
        }

        _ = try await client.resumeThread(
            threadID: currentTask.threadID,
            in: workspace,
            model: model
        )
        let turnResponse = try await client.startTurn(
            threadID: currentTask.threadID,
            prompt: prompt,
            in: workspace,
            model: model,
            reasoningEffort: reasoningEffort
        )
        await taskStore.registerStartedTurn(
            threadID: currentTask.threadID,
            turn: turnResponse.turn
        )
    }

    func interrupt(task: CodexAgentTaskSnapshot) async throws {
        guard let turnID = task.turnID, !task.status.isTerminal else { return }
        try await client.interruptTurn(
            threadID: task.threadID,
            turnID: turnID
        )
    }

    func resolve(
        approval: CodexAgentApproval,
        decision: CodexAgentApprovalDecision
    ) async throws {
        if approval.method == "item/permissions/requestApproval" {
            try await client.respond(
                to: approval.requestID,
                with: CodexAgentPermissionsApprovalResponse(
                    permissions: decision == .accept || decision == .acceptForSession
                        ? approval.requestedPermissions ?? .object([:])
                        : .object([:]),
                    scope: decision == .acceptForSession ? .session : .turn
                )
            )
        } else {
            try await client.respond(
                to: approval.requestID,
                with: CodexAgentApprovalDecisionResponse(decision: decision)
            )
        }

        // Keep the approval visible if the app-server response fails.
        await taskStore.resolveApproval(requestID: approval.requestID)
    }

    func resolve(
        userInputRequest: CodexAgentUserInputRequest,
        answersByQuestionID: [String: String]
    ) async throws {
        guard await taskStore.beginManualUserInputResolution(
            requestID: userInputRequest.requestID
        ) else {
            return
        }

        let answers = Dictionary(uniqueKeysWithValues: userInputRequest.questions.map { question in
            let answer = answersByQuestionID[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                question.id,
                CodexAgentUserInputAnswer(
                    answers: answer.isEmpty ? [] : [answer]
                )
            )
        })
        do {
            try await client.respond(
                to: userInputRequest.requestID,
                with: CodexAgentUserInputResponse(answers: answers)
            )
        } catch {
            await taskStore.abandonUserInputResolution(
                requestID: userInputRequest.requestID
            )
            throw error
        }
        await taskStore.resolveUserInput(requestID: userInputRequest.requestID)
    }

    func snoozeAutomaticResolution(
        for userInputRequest: CodexAgentUserInputRequest
    ) async {
        await taskStore.snoozeAutomaticUserInputResolution(
            requestID: userInputRequest.requestID
        )
    }

    private static func taskTitle(from prompt: String) -> String {
        let normalizedPrompt = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard normalizedPrompt.count > 72 else { return normalizedPrompt }
        return String(normalizedPrompt.prefix(69)) + "..."
    }
}
