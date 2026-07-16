//
//  CodexCompanionService.swift
//  leanring-buddy
//
//  Response-only companion and composition turns backed by ChatGPT Codex auth.
//

import Foundation

enum CodexCompanionMode: Hashable, Sendable {
    case companion
    case composition
}

enum CodexCompanionServiceError: LocalizedError, Equatable, Sendable {
    case chatGPTSubscriptionRequired
    case defaultModelUnavailable
    case invalidLocalImagePath(String)
    case responseTimedOut
    case turnFailed(String)
    case turnInterrupted

    var errorDescription: String? {
        switch self {
        case .chatGPTSubscriptionRequired:
            return "Sign in to Codex with a ChatGPT subscription before using the companion service."
        case .defaultModelUnavailable:
            return "Codex app-server did not advertise a default model."
        case .invalidLocalImagePath(let path):
            return "The companion image path must be absolute: \(path)"
        case .responseTimedOut:
            return "Codex did not finish the companion response before the timeout."
        case .turnFailed(let message):
            return message
        case .turnInterrupted:
            return "The companion response was interrupted."
        }
    }
}

actor CodexCompanionService {
    private struct TurnKey: Hashable, Sendable {
        let threadID: String
        let turnID: String
    }

    private enum CapturedTurnResult: Sendable {
        case response(String)
        case failure(CodexCompanionServiceError)
    }

    private static let defaultExtraAppServerArguments = [
        "-c",
        "mcp_servers={}"
    ]
    private static let responseOnlyDeveloperInstructions = """
    Do not use tools, commands, MCP servers, skills, web search, or filesystem inspection. \
    Do not modify files or external state. Use only the user text and local images supplied \
    in the turn, and return only the requested response text.
    """

    private let client: CodexAppServerClient
    private let workingDirectory: String
    private let responseTimeoutNanoseconds: UInt64

    private var selectedModel: String?
    private var connectionTask: Task<String, Error>?
    private var threadIDsByMode: [CodexCompanionMode: String] = [:]
    private var capturedResultsByTurn: [TurnKey: CapturedTurnResult] = [:]
    private var responseContinuationsByTurn: [
        TurnKey: CheckedContinuation<String, Error>
    ] = [:]
    private var responseTimeoutTasksByTurn: [TurnKey: Task<Void, Never>] = [:]
    private var notificationDrainTask: Task<Void, Never>?
    private var serverRequestDrainTask: Task<Void, Never>?

    init(
        client: CodexAppServerClient,
        workingDirectory: String = FileManager.default.temporaryDirectory.path,
        responseTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.client = client
        self.workingDirectory = workingDirectory
        self.responseTimeoutNanoseconds = max(1, responseTimeoutNanoseconds)
    }

    static func makeLive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        clientVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
        extraAppServerArguments: [String] = defaultExtraAppServerArguments
    ) throws -> CodexCompanionService {
        CodexCompanionService(
            client: try CodexAppServerClient.makeLive(
                environment: environment,
                bundleResourceURL: bundleResourceURL,
                clientVersion: clientVersion,
                extraAppServerArguments: extraAppServerArguments
            )
        )
    }

    func respond(
        mode: CodexCompanionMode,
        prompt: String,
        localImagePaths: [String] = [],
        developerInstructions: String? = nil
    ) async throws -> String {
        let normalizedPrompt = try normalizedPrompt(prompt)
        let normalizedLocalImagePaths = try normalizedLocalImagePaths(localImagePaths)
        do {
            try Task.checkCancellation()
            let model = try await connectAndSelectDefaultModelIfNeeded()
            try Task.checkCancellation()
            let threadID = try await threadID(
                for: mode,
                model: model,
                developerInstructions: developerInstructions
            )
            try Task.checkCancellation()
            defer {
                // Companion turns intentionally retain in-session context. Each
                // composition request is independent so field text cannot inherit
                // unrelated text from a previous insertion.
                if mode == .composition {
                    threadIDsByMode.removeValue(forKey: mode)
                }
            }
            let turnResponse = try await startTurn(
                threadID: threadID,
                prompt: normalizedPrompt,
                localImagePaths: normalizedLocalImagePaths,
                model: model
            )
            let turnID = turnResponse.turn.id
            if Task.isCancelled {
                try? await client.interruptTurn(
                    threadID: threadID,
                    turnID: turnID
                )
                throw CancellationError()
            }
            let turnKey = TurnKey(threadID: threadID, turnID: turnID)
            let client = self.client
            defer { clearCapturedResponseState(turnKey: turnKey) }

            do {
                return try await withTaskCancellationHandler {
                    try await waitForAgentResponse(turnKey: turnKey)
                } onCancel: {
                    Task {
                        await self.cancelResponseWaiter(turnKey: turnKey)
                        try? await client.interruptTurn(
                            threadID: threadID,
                            turnID: turnID
                        )
                    }
                }
            } catch is CancellationError {
                threadIDsByMode.removeValue(forKey: mode)
                throw CancellationError()
            } catch let serviceError as CodexCompanionServiceError {
                if serviceError == .responseTimedOut {
                    try? await client.interruptTurn(
                        threadID: threadID,
                        turnID: turnID
                    )
                }
                threadIDsByMode.removeValue(forKey: mode)
                throw serviceError
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let serviceError as CodexCompanionServiceError {
            throw serviceError
        } catch {
            await resetConnectionAfterUnexpectedFailure()
            throw error
        }
    }

    /// Developer instructions are fixed when a mode's persistent thread is created.
    /// Reset the mode before responding when a caller needs to replace that contract.
    func reset(mode: CodexCompanionMode) {
        threadIDsByMode.removeValue(forKey: mode)
    }

    func stop() async {
        failAllPendingResponseWaiters(with: CancellationError())
        notificationDrainTask?.cancel()
        serverRequestDrainTask?.cancel()
        notificationDrainTask = nil
        serverRequestDrainTask = nil
        selectedModel = nil
        connectionTask?.cancel()
        connectionTask = nil
        threadIDsByMode.removeAll()
        capturedResultsByTurn.removeAll()
        await client.stop()
    }

    private func connectAndSelectDefaultModelIfNeeded() async throws -> String {
        if let selectedModel {
            return selectedModel
        }

        if let connectionTask {
            let model = try await connectionTask.value
            completeConnection(model: model)
            return model
        }

        let client = self.client
        let connectionTask = Task { () throws -> String in
            let session = try await client.connect()
            guard session.account.isUsingChatGPTSubscription else {
                throw CodexCompanionServiceError.chatGPTSubscriptionRequired
            }
            let modelListResponse: CodexModelListResponse =
                try await client.sendRequest(
                    method: "model/list",
                    parameters: CodexModelListParameters()
                )
            guard let defaultModel = modelListResponse.data
                .first(where: \.isDefault)?
                .model
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !defaultModel.isEmpty else {
                throw CodexCompanionServiceError.defaultModelUnavailable
            }
            return defaultModel
        }
        self.connectionTask = connectionTask
        do {
            let model = try await connectionTask.value
            completeConnection(model: model)
            return model
        } catch {
            // Client streams remain valid across a stopped and reconnected
            // transport. Keep their single consumers alive so a setup retry
            // cannot lose the first notification to a canceled iterator.
            self.connectionTask = nil
            await client.stop()
            throw error
        }
    }

    private func completeConnection(model: String) {
        if selectedModel == nil {
            selectedModel = model
            startDrainingServerStreams()
        }
        connectionTask = nil
    }

    private func resetConnectionAfterUnexpectedFailure() async {
        selectedModel = nil
        connectionTask?.cancel()
        connectionTask = nil
        threadIDsByMode.removeAll()
        await client.stop()
    }

    private func startDrainingServerStreams() {
        if notificationDrainTask == nil {
            notificationDrainTask = Task { [
                weak self,
                notifications = client.notifications
            ] in
                for await notification in notifications {
                    guard !Task.isCancelled else { return }
                    await self?.capture(notification: notification)
                }
            }
        }

        if serverRequestDrainTask == nil {
            let client = self.client
            serverRequestDrainTask = Task { [serverRequests = client.serverRequests] in
                for await serverRequest in serverRequests {
                    guard !Task.isCancelled else { return }
                    try? await client.respondWithError(
                        to: serverRequest.id,
                        code: -32601,
                        message: "The response-only companion service does not accept server requests."
                    )
                }
            }
        }
    }

    private func threadID(
        for mode: CodexCompanionMode,
        model: String,
        developerInstructions: String?
    ) async throws -> String {
        if let existingThreadID = threadIDsByMode[mode] {
            return existingThreadID
        }

        let threadResponse: CodexThreadStartResponse = try await client.sendRequest(
            method: "thread/start",
            parameters: CodexThreadStartParameters(
                cwd: workingDirectory,
                approvalPolicy: .never,
                approvalsReviewer: .user,
                sandbox: .readOnly,
                ephemeral: true,
                model: model,
                developerInstructions: combinedDeveloperInstructions(
                    developerInstructions
                )
            )
        )
        threadIDsByMode[mode] = threadResponse.thread.id
        return threadResponse.thread.id
    }

    private func startTurn(
        threadID: String,
        prompt: String,
        localImagePaths: [String],
        model: String
    ) async throws -> CodexTurnStartResponse {
        var turnInputs: [CodexUserInput] = [
            .text(CodexTextUserInput(text: prompt))
        ]
        turnInputs.append(contentsOf: localImagePaths.map { localImagePath in
            .localImage(CodexLocalImageUserInput(path: localImagePath))
        })

        return try await client.sendRequest(
            method: "turn/start",
            parameters: CodexTurnStartParameters(
                threadId: threadID,
                input: turnInputs,
                cwd: workingDirectory,
                approvalPolicy: .never,
                approvalsReviewer: .user,
                sandboxPolicy: .readOnly(CodexReadOnlySandboxPolicy()),
                model: model,
                effort: nil,
                clientUserMessageId: UUID().uuidString
            )
        )
    }

    private func waitForAgentResponse(turnKey: TurnKey) async throws -> String {
        try Task.checkCancellation()

        if let capturedResult = capturedResultsByTurn[turnKey] {
            return try response(from: capturedResult)
        }

        return try await withCheckedThrowingContinuation { continuation in
            responseContinuationsByTurn[turnKey] = continuation
            let responseTimeoutNanoseconds = self.responseTimeoutNanoseconds
            responseTimeoutTasksByTurn[turnKey] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: responseTimeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.responseDidTimeOut(turnKey: turnKey)
            }
        }
    }

    private func capture(notification: CodexAppServerNotification) {
        switch notification.method {
        case "item/completed":
            guard let parameters = try? notification.decodeParameters(
                as: CodexAgentItemCompletedNotification.self
            ),
            let responseText = finalAgentResponseText(
                in: parameters.item,
                acceptsUnknownPhase: false
            ) else {
                return
            }
            capture(
                result: .response(responseText),
                turnKey: TurnKey(
                    threadID: parameters.threadId,
                    turnID: parameters.turnId
                )
            )
        case "turn/completed":
            guard let parameters = try? notification.decodeParameters(
                as: CodexTurnLifecycleNotification.self
            ) else {
                return
            }
            let turnKey = TurnKey(
                threadID: parameters.threadId,
                turnID: parameters.turn.id
            )

            if let responseText = finalAgentResponseText(
                in: parameters.turn
            ) {
                capture(result: .response(responseText), turnKey: turnKey)
                return
            }

            switch parameters.turn.status {
            case .failed:
                capture(
                    result: .failure(
                        .turnFailed(
                            parameters.turn.error?.message
                                ?? "Codex could not complete the companion response."
                        )
                    ),
                    turnKey: turnKey
                )
            case .interrupted:
                capture(result: .failure(.turnInterrupted), turnKey: turnKey)
            case .completed:
                // Some app-server builds deliver the completed agent item
                // immediately after the terminal turn notification. Keep
                // waiting for that authoritative item instead of locking in
                // a false missing-response failure.
                return
            case .inProgress, .unknown:
                return
            }
        default:
            return
        }
    }

    private func capture(
        result: CapturedTurnResult,
        turnKey: TurnKey
    ) {
        guard capturedResultsByTurn[turnKey] == nil else { return }

        capturedResultsByTurn[turnKey] = result
        responseTimeoutTasksByTurn.removeValue(forKey: turnKey)?.cancel()
        guard let continuation = responseContinuationsByTurn.removeValue(
            forKey: turnKey
        ) else {
            return
        }

        switch result {
        case .response(let responseText):
            continuation.resume(returning: responseText)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func responseDidTimeOut(turnKey: TurnKey) {
        capture(result: .failure(.responseTimedOut), turnKey: turnKey)
    }

    private func cancelResponseWaiter(turnKey: TurnKey) {
        responseTimeoutTasksByTurn.removeValue(forKey: turnKey)?.cancel()
        responseContinuationsByTurn.removeValue(forKey: turnKey)?
            .resume(throwing: CancellationError())
    }

    private func clearCapturedResponseState(turnKey: TurnKey) {
        responseTimeoutTasksByTurn.removeValue(forKey: turnKey)?.cancel()
        responseContinuationsByTurn.removeValue(forKey: turnKey)
        capturedResultsByTurn.removeValue(forKey: turnKey)
    }

    private func failAllPendingResponseWaiters(with error: Error) {
        let responseContinuations = Array(responseContinuationsByTurn.values)
        responseContinuationsByTurn.removeAll()
        for responseTimeoutTask in responseTimeoutTasksByTurn.values {
            responseTimeoutTask.cancel()
        }
        responseTimeoutTasksByTurn.removeAll()
        for responseContinuation in responseContinuations {
            responseContinuation.resume(throwing: error)
        }
    }

    private func response(from result: CapturedTurnResult) throws -> String {
        switch result {
        case .response(let responseText):
            return responseText
        case .failure(let error):
            throw error
        }
    }

    private func finalAgentResponseText(in turn: CodexTurn) -> String? {
        for item in turn.items.reversed() {
            if let responseText = finalAgentResponseText(
                in: item,
                acceptsUnknownPhase: false
            ) {
                return responseText
            }
        }

        // Older app-server versions may omit the phase. Only accept those
        // messages after the owning turn is terminal, never as an interim item.
        for item in turn.items.reversed() {
            if let responseText = finalAgentResponseText(
                in: item,
                acceptsUnknownPhase: true
            ) {
                return responseText
            }
        }
        return nil
    }

    private func finalAgentResponseText(
        in item: CodexJSONValue,
        acceptsUnknownPhase: Bool
    ) -> String? {
        guard let itemObject = item.objectValue,
              itemObject["type"]?.stringValue == "agentMessage",
              let responseText = itemObject["text"]?.stringValue else {
            return nil
        }
        let phase = itemObject["phase"]?.stringValue
        guard phase == "final_answer"
                || (phase == nil && acceptsUnknownPhase) else {
            return nil
        }
        let normalizedResponseText = responseText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalizedResponseText.isEmpty ? nil : normalizedResponseText
    }

    private func normalizedPrompt(_ prompt: String) throws -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw CodexAppServerError.emptyAgentPrompt
        }
        return normalizedPrompt
    }

    private func normalizedLocalImagePaths(
        _ localImagePaths: [String]
    ) throws -> [String] {
        try localImagePaths.map { localImagePath in
            let normalizedPath = localImagePath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard normalizedPath.hasPrefix("/") else {
                throw CodexCompanionServiceError.invalidLocalImagePath(localImagePath)
            }
            return normalizedPath
        }
    }

    private func combinedDeveloperInstructions(
        _ developerInstructions: String?
    ) -> String {
        let normalizedDeveloperInstructions = developerInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedDeveloperInstructions,
              !normalizedDeveloperInstructions.isEmpty else {
            return Self.responseOnlyDeveloperInstructions
        }
        return normalizedDeveloperInstructions
            + "\n\n"
            + Self.responseOnlyDeveloperInstructions
    }
}
