//
//  AgentPresentationModel.swift
//  leanring-buddy
//
//  Main-actor bridge between the Codex agent runtime and every agent HUD surface.
//

import AppKit
import Combine
import Foundation

enum AgentConnectionPhase: Equatable {
    case idle
    case connecting
    case connected(accountLabel: String)
    case needsAuthentication
    case failed(message: String)
}

enum AgentHUDRoute: Equatable {
    case overview
    case task(threadID: String)
}

@MainActor
final class AgentPresentationModel: ObservableObject {
    @Published private(set) var connectionPhase: AgentConnectionPhase = .idle
    @Published private(set) var taskSnapshots: [CodexAgentTaskSnapshot] = []
    @Published private(set) var workspacePath: String?
    @Published private(set) var isPerformingOperation = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authenticationCanStartAgain = false
    @Published private(set) var tokenLayoutRevision = 0
    @Published private(set) var agentAttentionRequest: CodexAgentAttentionRequest?
    @Published var route: AgentHUDRoute = .overview
    @Published var isNotchExpanded = false
    @Published var newTaskPrompt = ""
    @Published var followUpPrompt = ""
    @Published var operationErrorMessage: String?

    private static let workspacePathDefaultsKey = "clickyAgentWorkspacePath"

    private let coordinatorFactory: () throws -> CodexAgentCoordinator
    private var coordinator: CodexAgentCoordinator?
    private var snapshotMonitoringTask: Task<Void, Never>?
    private var failureMonitoringTask: Task<Void, Never>?
    private var authenticationMonitoringTask: Task<Void, Never>?
    private var displayIdentifierByThreadID: [String: CGDirectDisplayID] = [:]
    private var dismissedTokenThreadIDs: Set<String> = []
    private var maximumReceivedEventSequence: Int64 = 0
    private var sessionGeneration: UInt64 = 0
    private var authenticationAttemptGeneration: UInt64 = 0
    private var activeLoginID: String?
    private var hasStartedAuthenticationAttempt = false
    private var allowsMissingLoginIDCompletion = true
    private static let authenticationTimeout: Duration = .seconds(300)

    init(
        coordinatorFactory: @escaping () throws -> CodexAgentCoordinator = {
            try CodexAgentCoordinator.makeLive()
        }
    ) {
        self.coordinatorFactory = coordinatorFactory

        if let savedWorkspacePath = UserDefaults.standard.string(
            forKey: Self.workspacePathDefaultsKey
        ),
        FileManager.default.fileExists(atPath: savedWorkspacePath) {
            workspacePath = savedWorkspacePath
        }
    }

    deinit {
        snapshotMonitoringTask?.cancel()
        failureMonitoringTask?.cancel()
        authenticationMonitoringTask?.cancel()
    }

    var runningTasks: [CodexAgentTaskSnapshot] {
        taskSnapshots.filter { !$0.status.isTerminal }
    }

    var completedTasks: [CodexAgentTaskSnapshot] {
        taskSnapshots.filter(\.status.isTerminal)
    }

    var selectedTask: CodexAgentTaskSnapshot? {
        guard case .task(let selectedThreadID) = route else { return nil }
        return taskSnapshots.first { $0.threadID == selectedThreadID }
    }

    var spokenAgentConversationContext: SpokenAgentConversationContext {
        if selectedTask?.pendingUserInputs.isEmpty == false {
            return .waitingForInput
        }
        let tasksWaitingForInput = runningTasks.filter {
            !$0.pendingUserInputs.isEmpty
        }
        if tasksWaitingForInput.count == 1 {
            return .waitingForInput
        }
        if tasksWaitingForInput.count > 1 {
            return .ambiguous
        }
        if selectedTask != nil { return .selected }
        if runningTasks.count == 1 { return .soleRunning }
        if runningTasks.count > 1 { return .ambiguous }
        return .none
    }

    var spokenAgentStatusSummary: String {
        switch runningTasks.count {
        case 0:
            return "No agents are running."
        case 1:
            return "One agent is running."
        default:
            return "\(runningTasks.count) agents are running."
        }
    }

    var canRunTask: Bool {
        connectionPhase.isConnected
            && workspacePath != nil
            && !newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isPerformingOperation
    }

    var canRetryConnection: Bool {
        if case .failed = connectionPhase { return true }
        return false
    }

    var canSignInWithChatGPT: Bool {
        connectionPhase == .needsAuthentication
            && coordinator != nil
            && !isAuthenticating
    }

    var canCancelChatGPTSignIn: Bool {
        connectionPhase == .needsAuthentication
            && coordinator != nil
            && isAuthenticating
    }

    func start() {
        guard coordinator == nil else { return }

        sessionGeneration &+= 1
        authenticationAttemptGeneration &+= 1
        let expectedGeneration = sessionGeneration
        authenticationCanStartAgain = false
        hasStartedAuthenticationAttempt = false
        allowsMissingLoginIDCompletion = true
        maximumReceivedEventSequence = 0
        connectionPhase = .connecting
        do {
            let liveCoordinator = try coordinatorFactory()
            coordinator = liveCoordinator
            monitorSnapshots(
                from: liveCoordinator,
                expectedGeneration: expectedGeneration
            )
            monitorFailures(
                from: liveCoordinator,
                expectedGeneration: expectedGeneration
            )

            Task {
                do {
                    let session = try await liveCoordinator.start()
                    guard isCurrentSession(
                        liveCoordinator,
                        expectedGeneration: expectedGeneration
                    ) else { return }
                    guard session.account.isAuthenticated else {
                        connectionPhase = .needsAuthentication
                        return
                    }

                    connectionPhase = .connected(
                        accountLabel: Self.accountLabel(from: session.account)
                    )
                    await loadHistoryIfPossible()
                    let snapshots = await liveCoordinator.currentSnapshots()
                    guard isCurrentSession(
                        liveCoordinator,
                        expectedGeneration: expectedGeneration
                    ) else { return }
                    receiveSnapshots(snapshots)
                } catch {
                    guard isCurrentSession(
                        liveCoordinator,
                        expectedGeneration: expectedGeneration
                    ) else { return }
                    coordinator = nil
                    snapshotMonitoringTask?.cancel()
                    snapshotMonitoringTask = nil
                    failureMonitoringTask?.cancel()
                    failureMonitoringTask = nil
                    connectionPhase = .failed(message: error.localizedDescription)
                }
            }
        } catch {
            coordinator = nil
            connectionPhase = .failed(message: error.localizedDescription)
        }
    }

    func stop() {
        sessionGeneration &+= 1
        authenticationAttemptGeneration &+= 1
        authenticationMonitoringTask?.cancel()
        authenticationMonitoringTask = nil
        isAuthenticating = false
        let loginIDToCancel = activeLoginID
        activeLoginID = nil
        snapshotMonitoringTask?.cancel()
        snapshotMonitoringTask = nil
        failureMonitoringTask?.cancel()
        failureMonitoringTask = nil
        guard let coordinator else { return }
        self.coordinator = nil
        Task {
            if let loginIDToCancel {
                try? await coordinator.cancelChatGPTLogin(loginID: loginIDToCancel)
            }
            await coordinator.stop()
        }
    }

    func retryConnection() {
        stop()
        operationErrorMessage = nil
        connectionPhase = .idle
        start()
    }

    func dismissOperationError() {
        operationErrorMessage = nil
    }

    func signInWithChatGPT() {
        guard canSignInWithChatGPT, let coordinator else { return }

        if hasStartedAuthenticationAttempt {
            allowsMissingLoginIDCompletion = false
        }
        hasStartedAuthenticationAttempt = true
        let allowsMissingLoginID = allowsMissingLoginIDCompletion
        authenticationAttemptGeneration &+= 1
        let expectedAuthenticationAttempt = authenticationAttemptGeneration
        let expectedGeneration = sessionGeneration
        isAuthenticating = true
        authenticationCanStartAgain = false
        operationErrorMessage = nil
        authenticationMonitoringTask?.cancel()
        authenticationMonitoringTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ) {
                    isAuthenticating = false
                    authenticationMonitoringTask = nil
                }
            }

            do {
                let loginResponse = try await coordinator.startChatGPTLogin()
                guard isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ), !Task.isCancelled else {
                    try? await coordinator.cancelChatGPTLogin(loginID: loginResponse.loginId)
                    return
                }
                activeLoginID = loginResponse.loginId
                guard let authenticationURL = URL(string: loginResponse.authUrl),
                      authenticationURL.scheme?.lowercased() == "https",
                      NSWorkspace.shared.open(authenticationURL) else {
                    try? await coordinator.cancelChatGPTLogin(loginID: loginResponse.loginId)
                    guard isCurrentAuthenticationAttempt(
                        coordinator,
                        expectedGeneration: expectedGeneration,
                        expectedAuthenticationAttempt: expectedAuthenticationAttempt
                    ) else { return }
                    activeLoginID = nil
                    allowsMissingLoginIDCompletion = false
                    authenticationCanStartAgain = true
                    operationErrorMessage = "Clicky could not open the Codex sign-in page. Try signing in from the Codex or ChatGPT app, then reconnect."
                    return
                }

                let loginCompletion: CodexAppServerAccountLoginCompletedNotification
                do {
                    loginCompletion = try await Self.waitForLoginCompletion(
                        in: coordinator.accountLoginCompletions,
                        activeLoginID: loginResponse.loginId,
                        allowsMissingLoginID: allowsMissingLoginID,
                        timeout: Self.authenticationTimeout
                    )
                } catch CodexAppServerError.loginTimedOut {
                    try? await coordinator.cancelChatGPTLogin(loginID: loginResponse.loginId)
                    guard isCurrentAuthenticationAttempt(
                        coordinator,
                        expectedGeneration: expectedGeneration,
                        expectedAuthenticationAttempt: expectedAuthenticationAttempt
                    ) else { return }
                    activeLoginID = nil
                    allowsMissingLoginIDCompletion = false
                    authenticationCanStartAgain = true
                    connectionPhase = .needsAuthentication
                    operationErrorMessage = CodexAppServerError.loginTimedOut.localizedDescription
                    return
                }

                guard isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ) else { return }
                activeLoginID = nil
                if loginCompletion.loginId == nil {
                    allowsMissingLoginIDCompletion = false
                }
                guard loginCompletion.success else {
                    authenticationCanStartAgain = true
                    connectionPhase = .needsAuthentication
                    operationErrorMessage = loginCompletion.error
                        ?? "Codex sign-in did not complete. Start again when you are ready."
                    return
                }

                let accountResponse = try await coordinator.refreshAccount()
                guard isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ), accountResponse.isAuthenticated else {
                    if isCurrentAuthenticationAttempt(
                        coordinator,
                        expectedGeneration: expectedGeneration,
                        expectedAuthenticationAttempt: expectedAuthenticationAttempt
                    ) {
                        authenticationCanStartAgain = true
                        connectionPhase = .needsAuthentication
                        operationErrorMessage = "Codex reported a completed sign-in, but no account is available. Start again."
                    }
                    return
                }
                authenticationCanStartAgain = false
                connectionPhase = .connected(
                    accountLabel: Self.accountLabel(from: accountResponse)
                )
                await loadHistoryIfPossible()
                let snapshots = await coordinator.currentSnapshots()
                guard isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ) else { return }
                receiveSnapshots(snapshots)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAuthenticationAttempt(
                    coordinator,
                    expectedGeneration: expectedGeneration,
                    expectedAuthenticationAttempt: expectedAuthenticationAttempt
                ) else { return }
                activeLoginID = nil
                authenticationCanStartAgain = true
                connectionPhase = .needsAuthentication
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelChatGPTSignIn() {
        guard canCancelChatGPTSignIn, let coordinator else { return }

        authenticationAttemptGeneration &+= 1
        authenticationMonitoringTask?.cancel()
        authenticationMonitoringTask = nil
        isAuthenticating = false
        authenticationCanStartAgain = true
        allowsMissingLoginIDCompletion = false
        connectionPhase = .needsAuthentication
        operationErrorMessage = "Codex sign-in was canceled. Start again when you are ready."
        let loginIDToCancel = activeLoginID
        activeLoginID = nil

        guard let loginIDToCancel else { return }
        Task {
            try? await coordinator.cancelChatGPTLogin(loginID: loginIDToCancel)
        }
    }

    func chooseWorkspace() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Agent Folder"
        openPanel.prompt = "Choose"
        openPanel.message = "Codex agents can read and write inside this folder."
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true

        guard openPanel.runModal() == .OK, let selectedURL = openPanel.url else {
            return
        }

        do {
            let workspace = try CodexAgentWorkspace(directoryURL: selectedURL)
            workspacePath = workspace.path
            route = .overview
            tokenLayoutRevision &+= 1
            UserDefaults.standard.set(
                workspace.path,
                forKey: Self.workspacePathDefaultsKey
            )
            Task {
                await loadHistoryIfPossible()
            }
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    func startTask() {
        let prompt = newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            operationErrorMessage = "Enter a task for the agent."
            return
        }
        guard connectionPhase.isConnected else {
            operationErrorMessage = spokenTaskConnectionErrorMessage
            return
        }
        guard selectedWorkspace != nil else {
            operationErrorMessage = "Choose an Agent Folder, then start the prepared task."
            return
        }
        guard !isPerformingOperation else {
            operationErrorMessage = "Clicky is finishing another agent action. Try again when it finishes."
            return
        }
        guard let coordinator,
              let workspace = selectedWorkspace else {
            operationErrorMessage = "Reconnect Codex, then start the prepared task."
            return
        }

        let displayIdentifier = Self.displayIdentifierContainingMouse()
        let expectedGeneration = sessionGeneration
        isPerformingOperation = true
        operationErrorMessage = nil

        Task {
            defer {
                if isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) {
                    isPerformingOperation = false
                }
            }
            do {
                let threadID = try await coordinator.startTask(
                    prompt: prompt,
                    in: workspace
                )
                let snapshots = await coordinator.currentSnapshots()
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                receiveSnapshots(snapshots)
                if let displayIdentifier {
                    displayIdentifierByThreadID[threadID] = displayIdentifier
                    tokenLayoutRevision &+= 1
                }
                newTaskPrompt = ""
                route = .task(threadID: threadID)
                isNotchExpanded = true
            } catch {
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func startSpokenTask(prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        newTaskPrompt = trimmedPrompt
        route = .overview
        isNotchExpanded = true
        operationErrorMessage = nil

        guard connectionPhase.isConnected else {
            operationErrorMessage = spokenTaskConnectionErrorMessage
            return
        }
        guard selectedWorkspace != nil else {
            operationErrorMessage = "Choose an Agent Folder, then start the prepared task."
            return
        }
        guard !isPerformingOperation else {
            operationErrorMessage = "Clicky is finishing another agent action. Your spoken task is ready in the composer."
            return
        }

        startTask()
    }

    func sendFollowUp() {
        let prompt = followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedTask, !prompt.isEmpty else { return }
        beginFollowUp(
            prompt: prompt,
            on: selectedTask,
            clearsTypedComposerOnSuccess: true
        )
    }

    func sendSpokenFollowUp(prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        let targetTask: CodexAgentTaskSnapshot
        let tasksWaitingForInput = runningTasks.filter {
            !$0.pendingUserInputs.isEmpty
        }
        if let selectedTask,
           !selectedTask.pendingUserInputs.isEmpty {
            targetTask = selectedTask
        } else if tasksWaitingForInput.count == 1,
                  let waitingTask = tasksWaitingForInput.first {
            targetTask = waitingTask
        } else {
            let followUpTargetResolution = SpokenAgentFollowUpTargetResolver.resolve(
                selectedThreadID: selectedTask?.threadID,
                runningThreadIDs: runningTasks.map(\.threadID)
            )
            switch followUpTargetResolution {
            case .target(let threadID):
                guard let resolvedTargetTask = taskSnapshots.first(
                    where: { $0.threadID == threadID }
                ) else {
                    showOverview()
                    operationErrorMessage = "That agent is no longer available."
                    return
                }
                targetTask = resolvedTargetTask
            case .requiresSelection:
                showOverview()
                operationErrorMessage = "Open the agent you want to continue, then repeat the instruction."
                return
            case .missing:
                showOverview()
                operationErrorMessage = "Open a recent agent before giving it a follow-up."
                return
            }
        }

        showTask(threadID: targetTask.threadID)
        if let userInputRequest = targetTask.pendingUserInputs.first {
            guard userInputRequest.questions.count == 1,
                  let question = userInputRequest.questions.first else {
                operationErrorMessage = "This agent needs several answers. Use the open agent card to continue."
                return
            }
            resolveUserInput(
                userInputRequest,
                answersByQuestionID: [question.id: trimmedPrompt]
            )
            return
        }

        beginFollowUp(
            prompt: trimmedPrompt,
            on: targetTask,
            clearsTypedComposerOnSuccess: false
        )
    }

    private func beginFollowUp(
        prompt: String,
        on targetTask: CodexAgentTaskSnapshot,
        clearsTypedComposerOnSuccess: Bool
    ) {
        guard let coordinator else {
            operationErrorMessage = "Codex is disconnected. Reconnect, then repeat the follow-up."
            return
        }
        guard let workspace = workspace(for: targetTask) else {
            operationErrorMessage = "This agent's folder is no longer available."
            return
        }
        guard !isPerformingOperation else {
            operationErrorMessage = "Clicky is finishing another agent action. Repeat the follow-up when it finishes."
            return
        }

        isPerformingOperation = true
        operationErrorMessage = nil
        dismissedTokenThreadIDs.remove(targetTask.threadID)
        if displayIdentifierByThreadID[targetTask.threadID] == nil {
            displayIdentifierByThreadID[targetTask.threadID] = Self.displayIdentifierContainingMouse()
                ?? NSScreen.main.flatMap(Self.displayIdentifier)
        }
        tokenLayoutRevision &+= 1
        let expectedGeneration = sessionGeneration
        Task {
            defer {
                if isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) {
                    isPerformingOperation = false
                }
            }
            do {
                try await coordinator.followUp(
                    prompt: prompt,
                    on: targetTask,
                    in: workspace
                )
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                if clearsTypedComposerOnSuccess {
                    followUpPrompt = ""
                }
            } catch {
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func interruptSelectedTask() {
        guard let coordinator, let selectedTask else { return }
        interrupt(task: selectedTask, using: coordinator)
    }

    func interruptTask(threadID: String) {
        guard let coordinator,
              let task = taskSnapshots.first(where: { $0.threadID == threadID }) else {
            return
        }
        interrupt(task: task, using: coordinator)
    }

    func openWorkspace() {
        guard let workspacePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: workspacePath))
    }

    func openFileChange(_ activity: CodexAgentActivity) {
        guard activity.kind == .fileChange,
              let workspacePath else {
            return
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidateURL: URL
        if activity.summary.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: activity.summary)
        } else {
            candidateURL = workspaceURL.appendingPathComponent(activity.summary)
        }
        let resolvedCandidateURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedCandidateURL.path == workspaceURL.path
                || resolvedCandidateURL.path.hasPrefix(workspaceURL.path + "/"),
              FileManager.default.fileExists(atPath: resolvedCandidateURL.path) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([resolvedCandidateURL])
    }

    private func interrupt(
        task: CodexAgentTaskSnapshot,
        using coordinator: CodexAgentCoordinator
    ) {
        isPerformingOperation = true
        operationErrorMessage = nil
        let expectedGeneration = sessionGeneration

        Task {
            defer {
                if isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) {
                    isPerformingOperation = false
                }
            }
            do {
                try await coordinator.interrupt(task: task)
            } catch {
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func resolveApproval(
        _ approval: CodexAgentApproval,
        decision: CodexAgentApprovalDecision
    ) {
        guard let coordinator else { return }
        isPerformingOperation = true
        operationErrorMessage = nil
        let expectedGeneration = sessionGeneration

        Task {
            defer {
                if isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) {
                    isPerformingOperation = false
                }
            }
            do {
                try await coordinator.resolve(
                    approval: approval,
                    decision: decision
                )
            } catch {
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func resolveUserInput(
        _ userInputRequest: CodexAgentUserInputRequest,
        answersByQuestionID: [String: String]
    ) {
        guard let coordinator else { return }
        isPerformingOperation = true
        operationErrorMessage = nil
        let expectedGeneration = sessionGeneration

        Task {
            defer {
                if isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) {
                    isPerformingOperation = false
                }
            }
            do {
                try await coordinator.resolve(
                    userInputRequest: userInputRequest,
                    answersByQuestionID: answersByQuestionID
                )
            } catch {
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    func snoozeAutomaticUserInputResolution(
        _ userInputRequest: CodexAgentUserInputRequest
    ) {
        guard let coordinator else { return }
        Task {
            await coordinator.snoozeAutomaticResolution(
                for: userInputRequest
            )
        }
    }

    func showOverview() {
        route = .overview
        isNotchExpanded = true
    }

    func showTask(
        threadID: String,
        on displayIdentifier: CGDirectDisplayID? = nil
    ) {
        if let displayIdentifier {
            displayIdentifierByThreadID[threadID] = displayIdentifier
            tokenLayoutRevision &+= 1
        }
        route = .task(threadID: threadID)
        isNotchExpanded = true
    }

    func collapseNotch() {
        isNotchExpanded = false
    }

    func dismissTaskToken(threadID: String) {
        dismissedTokenThreadIDs.insert(threadID)
        tokenLayoutRevision &+= 1
        if case .task(let selectedThreadID) = route, selectedThreadID == threadID {
            route = .overview
        }
    }

    func tasks(for displayIdentifier: CGDirectDisplayID) -> [CodexAgentTaskSnapshot] {
        taskSnapshots.filter { task in
            displayIdentifierByThreadID[task.threadID] == displayIdentifier
                && !dismissedTokenThreadIDs.contains(task.threadID)
        }
    }

    private var selectedWorkspace: CodexAgentWorkspace? {
        guard let workspacePath else { return nil }
        return try? CodexAgentWorkspace(directoryURL: URL(fileURLWithPath: workspacePath))
    }

    private var spokenTaskConnectionErrorMessage: String {
        switch connectionPhase {
        case .needsAuthentication:
            return "Sign in with ChatGPT, then start the prepared task."
        case .failed:
            return "Reconnect Codex, then start the prepared task."
        case .connecting:
            return "Codex is still connecting. Your spoken task is ready in the composer."
        case .idle:
            return "Start Codex, then run the prepared task."
        case .connected:
            return "Codex is not ready to start this task yet."
        }
    }

    private func workspace(
        for task: CodexAgentTaskSnapshot
    ) -> CodexAgentWorkspace? {
        try? CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: task.workspacePath)
        )
    }

    private func monitorSnapshots(
        from coordinator: CodexAgentCoordinator,
        expectedGeneration: UInt64
    ) {
        snapshotMonitoringTask?.cancel()
        snapshotMonitoringTask = Task { [weak self] in
            for await snapshots in coordinator.snapshots {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                guard let self,
                      isCurrentSession(
                          coordinator,
                          expectedGeneration: expectedGeneration
                      ) else { return }
                receiveSnapshots(snapshots)
            }
        }
    }

    private func monitorFailures(
        from coordinator: CodexAgentCoordinator,
        expectedGeneration: UInt64
    ) {
        failureMonitoringTask?.cancel()
        failureMonitoringTask = Task { [weak self] in
            for await failure in coordinator.failures {
                guard !Task.isCancelled else { return }
                guard let self,
                      isCurrentSession(
                          coordinator,
                          expectedGeneration: expectedGeneration
                      ) else { return }
                authenticationMonitoringTask?.cancel()
                authenticationMonitoringTask = nil
                isAuthenticating = false
                authenticationAttemptGeneration &+= 1
                authenticationCanStartAgain = true
                activeLoginID = nil
                await coordinator.recordConnectionFailure(failure)
                let snapshots = await coordinator.currentSnapshots()
                guard isCurrentSession(
                    coordinator,
                    expectedGeneration: expectedGeneration
                ) else { return }
                receiveSnapshots(snapshots)
                isPerformingOperation = false
                operationErrorMessage = failure.localizedDescription
                connectionPhase = .failed(
                    message: failure.localizedDescription
                )
            }
        }
    }

    private func receiveSnapshots(_ snapshots: [CodexAgentTaskSnapshot]) {
        let maximumIncomingEventSequence = snapshots
            .map(\.lastEventSequence)
            .max() ?? 0
        guard maximumIncomingEventSequence >= maximumReceivedEventSequence else {
            return
        }
        maximumReceivedEventSequence = maximumIncomingEventSequence

        let fallbackDisplayIdentifier = Self.displayIdentifierContainingMouse()
            ?? NSScreen.main.flatMap(Self.displayIdentifier)

        var didChangeTokenLayout = false
        for snapshot in snapshots where !snapshot.status.isTerminal {
            dismissedTokenThreadIDs.remove(snapshot.threadID)
            if displayIdentifierByThreadID[snapshot.threadID] == nil {
                displayIdentifierByThreadID[snapshot.threadID] = fallbackDisplayIdentifier
                didChangeTokenLayout = true
            }
        }
        guard let workspacePath else {
            taskSnapshots = []
            agentAttentionRequest = nil
            return
        }
        let workspaceSnapshots = snapshots.filter { snapshot in
            snapshot.workspacePath == workspacePath
        }
        taskSnapshots = workspaceSnapshots

        let nextAttentionRequest = workspaceSnapshots.lazy
            .compactMap(\.pendingAttentionRequest)
            .first
        if nextAttentionRequest != agentAttentionRequest {
            agentAttentionRequest = nextAttentionRequest
            didChangeTokenLayout = true
        }

        if didChangeTokenLayout {
            tokenLayoutRevision &+= 1
        }
    }

    private func loadHistoryIfPossible() async {
        guard connectionPhase.isConnected,
              let coordinator,
              let workspace = selectedWorkspace else {
            return
        }
        let expectedGeneration = sessionGeneration

        do {
            _ = try await coordinator.loadHistory(in: workspace)
            let snapshots = await coordinator.currentSnapshots()
            guard isCurrentSession(
                coordinator,
                expectedGeneration: expectedGeneration
            ) else { return }
            receiveSnapshots(snapshots)
        } catch {
            guard isCurrentSession(
                coordinator,
                expectedGeneration: expectedGeneration
            ) else { return }
            operationErrorMessage = error.localizedDescription
        }
    }

    private func isCurrentSession(
        _ expectedCoordinator: CodexAgentCoordinator,
        expectedGeneration: UInt64
    ) -> Bool {
        sessionGeneration == expectedGeneration
            && coordinator === expectedCoordinator
    }

    private func isCurrentAuthenticationAttempt(
        _ expectedCoordinator: CodexAgentCoordinator,
        expectedGeneration: UInt64,
        expectedAuthenticationAttempt: UInt64
    ) -> Bool {
        isCurrentSession(
            expectedCoordinator,
            expectedGeneration: expectedGeneration
        ) && authenticationAttemptGeneration == expectedAuthenticationAttempt
    }

    private static func waitForLoginCompletion(
        in completions: AsyncStream<CodexAppServerAccountLoginCompletedNotification>,
        activeLoginID: String,
        allowsMissingLoginID: Bool,
        timeout: Duration
    ) async throws -> CodexAppServerAccountLoginCompletedNotification {
        try await withThrowingTaskGroup(
            of: CodexAppServerAccountLoginCompletedNotification.self
        ) { taskGroup in
            taskGroup.addTask {
                for await completion in completions {
                    try Task.checkCancellation()
                    if CodexAppServerLoginCompletionMatcher.matches(
                        completion,
                        activeLoginID: activeLoginID,
                        allowsMissingLoginID: allowsMissingLoginID
                    ) {
                        return completion
                    }
                }
                throw CancellationError()
            }
            taskGroup.addTask {
                try await Task.sleep(for: timeout)
                throw CodexAppServerError.loginTimedOut
            }

            defer { taskGroup.cancelAll() }
            guard let completion = try await taskGroup.next() else {
                throw CancellationError()
            }
            return completion
        }
    }

    private static func accountLabel(
        from accountResponse: CodexAppServerAccountReadResponse
    ) -> String {
        accountResponse.account?.email
            ?? accountResponse.account?.planType
            ?? "ChatGPT"
    }

    static func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private static func displayIdentifierContainingMouse() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens
            .first { $0.frame.contains(mouseLocation) }
            .flatMap(displayIdentifier)
    }

    static func preview(
        tasks: [CodexAgentTaskSnapshot],
        route: AgentHUDRoute = .overview,
        isExpanded: Bool = true
    ) -> AgentPresentationModel {
        let presentationModel = AgentPresentationModel {
            throw CodexAppServerError.executableNotFound
        }
        presentationModel.connectionPhase = .connected(accountLabel: "samarth@example.com")
        presentationModel.taskSnapshots = tasks
        presentationModel.workspacePath = "/Users/samarthgupta/Projects/clicky"
        presentationModel.route = route
        presentationModel.isNotchExpanded = isExpanded
        return presentationModel
    }
}

private extension AgentConnectionPhase {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
