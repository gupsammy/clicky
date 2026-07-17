import Foundation
import XCTest
@testable import ClickyAgentCore

final class CodexCompanionServiceTests: XCTestCase {
    func testProcessTransportAppendsConfigurableArguments() {
        XCTAssertEqual(
            CodexAppServerProcessTransport.processArguments(
                extraArguments: ["-c", "mcp_servers={}"]
            ),
            ["-c", "mcp_servers={}", "app-server", "--stdio"]
        )
    }

    func testUsesDefaultModelReadOnlyImageInputsAndPersistentModeThread() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .completed("first response"),
                .completed("second response"),
                .completed("composition response")
            ]
        )
        let service = makeService(transport: transport)

        let firstResponse = try await service.respond(
            mode: .companion,
            prompt: "  explain the marked region  ",
            localImagePaths: ["/tmp/clicky-capture.jpg"],
            developerInstructions: "  Use the existing spatial tag contract.  "
        )
        let secondResponse = try await service.respond(
            mode: .companion,
            prompt: "continue",
            developerInstructions: "This later instruction must be ignored."
        )
        let compositionResponse = try await service.respond(
            mode: .composition,
            prompt: "write the field text",
            localImagePaths: ["/tmp/clicky-composition.jpg"],
            developerInstructions: "Return only insertion text."
        )

        XCTAssertEqual(firstResponse, "first response")
        XCTAssertEqual(secondResponse, "second response")
        XCTAssertEqual(compositionResponse, "composition response")
        XCTAssertEqual(transport.requestCount(for: "model/list"), 1)
        XCTAssertEqual(transport.requestCount(for: "thread/start"), 2)
        XCTAssertEqual(transport.requestCount(for: "turn/start"), 3)
        XCTAssertEqual(transport.requestCount(for: "thread/read"), 0)

        let threadStartParameters = try parametersObject(
            transport.parameters(for: "thread/start").first
        )
        XCTAssertEqual(threadStartParameters["approvalPolicy"], .string("never"))
        XCTAssertEqual(threadStartParameters["sandbox"], .string("read-only"))
        XCTAssertEqual(threadStartParameters["ephemeral"], .boolean(true))
        XCTAssertEqual(threadStartParameters["model"], .string("gpt-default"))
        guard case .string(let developerInstructions)? =
                threadStartParameters["developerInstructions"] else {
            return XCTFail("Expected developer instructions")
        }
        XCTAssertTrue(developerInstructions.contains("Use the existing spatial tag contract."))
        XCTAssertTrue(developerInstructions.contains("Do not use tools"))
        XCTAssertFalse(developerInstructions.contains("later instruction"))

        let firstTurnParameters = try parametersObject(
            transport.parameters(for: "turn/start").first
        )
        XCTAssertEqual(firstTurnParameters["approvalPolicy"], .string("never"))
        XCTAssertEqual(firstTurnParameters["model"], .string("gpt-default"))
        let sandboxPolicy = try parametersObject(firstTurnParameters["sandboxPolicy"])
        XCTAssertEqual(sandboxPolicy["type"], .string("readOnly"))
        XCTAssertEqual(sandboxPolicy["networkAccess"], .boolean(false))

        let turnInputs = try arrayValue(firstTurnParameters["input"])
        XCTAssertEqual(turnInputs.count, 2)
        XCTAssertEqual(
            try parametersObject(turnInputs[0]),
            [
                "type": .string("text"),
                "text": .string("explain the marked region")
            ]
        )
        XCTAssertEqual(
            try parametersObject(turnInputs[1]),
            [
                "type": .string("localImage"),
                "path": .string("/tmp/clicky-capture.jpg")
            ]
        )

        await service.stop()
    }

    func testFailedTurnReturnsFailureAndResetsModeThread() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .failed("vision failed"),
                .completed("recovered")
            ]
        )
        let service = makeService(transport: transport)

        do {
            _ = try await service.respond(
                mode: .companion,
                prompt: "inspect this"
            )
            XCTFail("Expected the failed turn to throw")
        } catch let error as CodexCompanionServiceError {
            XCTAssertEqual(error, .turnFailed("vision failed"))
        }

        let recoveredResponse = try await service.respond(
            mode: .companion,
            prompt: "try again"
        )
        XCTAssertEqual(recoveredResponse, "recovered")
        XCTAssertEqual(transport.requestCount(for: "thread/start"), 2)

        await service.stop()
    }

    func testTurnCompletedNotificationCanCarryFinalResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.completedInTurn("turn response")]
        )
        let service = makeService(transport: transport)

        let response = try await service.respond(
            mode: .companion,
            prompt: "respond"
        )

        XCTAssertEqual(response, "turn response")
        XCTAssertEqual(transport.requestCount(for: "thread/read"), 0)
        await service.stop()
    }

    func testCompositionUsesIndependentEphemeralThreads() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .completed("first composition"),
                .completed("second composition")
            ]
        )
        let service = makeService(transport: transport)

        _ = try await service.respond(mode: .composition, prompt: "first")
        _ = try await service.respond(mode: .composition, prompt: "second")

        XCTAssertEqual(transport.requestCount(for: "thread/start"), 2)
        for parameters in transport.parameters(for: "thread/start") {
            XCTAssertEqual(
                try parametersObject(parameters)["ephemeral"],
                .boolean(true)
            )
        }
        await service.stop()
    }

    func testTimeoutInterruptsTurn() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.inProgress]
        )
        let service = makeService(
            transport: transport,
            responseTimeoutNanoseconds: 2_000_000
        )

        do {
            _ = try await service.respond(
                mode: .composition,
                prompt: "compose"
            )
            XCTFail("Expected the response to time out")
        } catch let error as CodexCompanionServiceError {
            XCTAssertEqual(error, .responseTimedOut)
        }

        XCTAssertEqual(transport.requestCount(for: "turn/interrupt"), 1)
        await service.stop()
    }

    func testCancellationInterruptsTurn() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.inProgress]
        )
        let service = makeService(
            transport: transport,
            responseTimeoutNanoseconds: 5_000_000_000
        )
        let responseTask = Task {
            try await service.respond(
                mode: .companion,
                prompt: "wait"
            )
        }

        for _ in 0..<100 where transport.requestCount(for: "turn/start") == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        responseTask.cancel()

        do {
            _ = try await responseTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        for _ in 0..<100 where transport.requestCount(for: "turn/interrupt") == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(transport.requestCount(for: "turn/interrupt"), 1)
        await service.stop()
    }

    func testRapidReplacementSharesColdConnectionAndCancelsFirstResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.completed("replacement response")],
            initializeResponseDelayNanoseconds: 20_000_000
        )
        let service = makeService(transport: transport)
        let firstResponseTask = Task {
            try await service.respond(
                mode: .companion,
                prompt: "first request"
            )
        }

        for _ in 0..<100 where transport.requestCount(for: "initialize") == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        firstResponseTask.cancel()

        let replacementResponse = try await service.respond(
            mode: .companion,
            prompt: "replacement request"
        )
        XCTAssertEqual(replacementResponse, "replacement response")

        do {
            _ = try await firstResponseTask.value
            XCTFail("Expected the replaced response to remain canceled")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(transport.startCallCount, 1)
        XCTAssertEqual(transport.requestCount(for: "initialize"), 1)
        XCTAssertEqual(transport.requestCount(for: "model/list"), 1)
        XCTAssertEqual(transport.requestCount(for: "turn/start"), 1)
        await service.stop()
    }

    func testInterimCommentaryIsNotReturnedAsTheCompanionResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .commentaryThenFinal(
                    commentary: "I will inspect the image first.",
                    finalResponse: "The final human-facing response."
                )
            ]
        )
        let service = makeService(transport: transport)

        let response = try await service.respond(
            mode: .companion,
            prompt: "respond"
        )

        XCTAssertEqual(response, "The final human-facing response.")
        await service.stop()
    }

    func testRejectsUnexpectedServerRequests() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.completed("ready")]
        )
        let service = makeService(transport: transport)
        _ = try await service.respond(mode: .companion, prompt: "connect")

        try transport.emitServerRequest(
            id: .integer(81),
            method: "item/tool/requestUserInput"
        )
        for _ in 0..<100 where transport.serverErrorResponseCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(transport.serverErrorResponseCodes, [-32601])
        await service.stop()
    }

    func testModelListFailureStopsAndRecoversOnNextResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [.completed("recovered")],
            modelListFailuresRemaining: 1
        )
        let service = makeService(transport: transport)

        do {
            _ = try await service.respond(mode: .companion, prompt: "first")
            XCTFail("Expected the initial model list request to fail")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(
                error,
                .protocolFailure(
                    code: -32001,
                    message: "Temporary model catalog failure"
                )
            )
        }

        let response = try await service.respond(
            mode: .companion,
            prompt: "retry"
        )
        XCTAssertEqual(response, "recovered")
        XCTAssertEqual(transport.requestCount(for: "model/list"), 2)
        await service.stop()
    }

    func testProcessFailureClearsSessionAndReconnectsOnNextResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .completed("first response"),
                .completed("recovered response")
            ],
            failingTurnStartRequestNumbers: [2]
        )
        let service = makeService(transport: transport)

        let firstResponse = try await service.respond(
            mode: .companion,
            prompt: "first"
        )
        XCTAssertEqual(firstResponse, "first response")

        do {
            _ = try await service.respond(
                mode: .companion,
                prompt: "trigger process failure"
            )
            XCTFail("Expected the simulated process failure")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(
                error,
                .processTerminated(
                    exitCode: -9,
                    standardError: "Simulated companion process failure"
                )
            )
        }

        XCTAssertEqual(transport.stopCallCount, 1)

        let recoveredResponse = try await service.respond(
            mode: .companion,
            prompt: "retry"
        )
        XCTAssertEqual(recoveredResponse, "recovered response")
        XCTAssertEqual(transport.startCallCount, 2)
        XCTAssertEqual(transport.requestCount(for: "model/list"), 2)
        XCTAssertEqual(transport.requestCount(for: "thread/start"), 2)
        XCTAssertEqual(transport.requestCount(for: "turn/start"), 3)

        await service.stop()
    }

    func testMidTurnProcessFailureFailsWaiterAndReconnectsOnNextResponse() async throws {
        let transport = CodexCompanionMockTransport(
            turnResults: [
                .inProgress,
                .completed("recovered response")
            ]
        )
        let service = makeService(
            transport: transport,
            responseTimeoutNanoseconds: 2_000_000_000
        )
        let expectedFailure = CodexAppServerError.processTerminated(
            exitCode: -9,
            standardError: "Simulated mid-turn process failure"
        )

        let inProgressResponse = Task {
            try await service.respond(
                mode: .companion,
                prompt: "wait for the process failure"
            )
        }
        for _ in 0..<100 where transport.requestCount(for: "turn/start") == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(transport.requestCount(for: "turn/start"), 1)

        transport.emitTermination(expectedFailure)

        do {
            _ = try await inProgressResponse.value
            XCTFail("Expected the active response to fail with the process")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, expectedFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recoveredResponse = try await service.respond(
            mode: .companion,
            prompt: "retry after process failure"
        )
        XCTAssertEqual(recoveredResponse, "recovered response")
        XCTAssertEqual(transport.startCallCount, 2)
        XCTAssertEqual(transport.requestCount(for: "model/list"), 2)
        XCTAssertEqual(transport.requestCount(for: "thread/start"), 2)
        XCTAssertEqual(transport.requestCount(for: "turn/start"), 2)

        await service.stop()
    }

    private func makeService(
        transport: CodexCompanionMockTransport,
        responseTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) -> CodexCompanionService {
        CodexCompanionService(
            client: CodexAppServerClient(
                transport: transport,
                clientInfo: CodexAppServerClientInfo(
                    name: "clicky_companion_tests",
                    title: "Clicky Companion Tests",
                    version: "1.0"
                )
            ),
            workingDirectory: "/tmp",
            responseTimeoutNanoseconds: responseTimeoutNanoseconds
        )
    }

    private func parametersObject(
        _ value: CodexJSONValue?
    ) throws -> [String: CodexJSONValue] {
        guard case .object(let objectValue) = value else {
            throw CodexAppServerError.malformedMessage
        }
        return objectValue
    }

    private func arrayValue(
        _ value: CodexJSONValue?
    ) throws -> [CodexJSONValue] {
        guard case .array(let arrayValue) = value else {
            throw CodexAppServerError.malformedMessage
        }
        return arrayValue
    }
}

final class CodexCompanionServiceLiveTests: XCTestCase {
    func testSubscriptionBackedLocalImageResponse() async throws {
        guard ProcessInfo.processInfo.environment["CLICKY_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set CLICKY_RUN_CODEX_INTEGRATION_TESTS=1 to run a response-only local-image turn")
        }

        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageURL = repositoryRootURL.appendingPathComponent("dmg-background.png")
        let service = try CodexCompanionService.makeLive(
            bundleResourceURL: nil,
            clientVersion: "integration-test"
        )

        do {
            let responseText = try await service.respond(
                mode: .composition,
                prompt: "Inspect the attached image and reply with only the words image received.",
                localImagePaths: [imageURL.path],
                developerInstructions: "Return only the requested response text."
            )
            XCTAssertEqual(responseText.lowercased(), "image received")
            await service.stop()
        } catch {
            await service.stop()
            throw error
        }
    }
}

private enum CodexCompanionMockTurnResult {
    case inProgress
    case completed(String)
    case completedInTurn(String)
    case commentaryThenFinal(commentary: String, finalResponse: String)
    case failed(String)
}

private final class CodexCompanionMockTransport: CodexAppServerTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var terminationHandler: (@Sendable (CodexAppServerError) -> Void)?
    private var parametersByMethod: [String: [CodexJSONValue]] = [:]
    private var turnResults: [CodexCompanionMockTurnResult]
    private var latestTurnResult: CodexCompanionMockTurnResult = .inProgress
    private var modelListFailuresRemaining: Int
    private var failingTurnStartRequestNumbers: Set<Int>
    private let initializeResponseDelayNanoseconds: UInt64
    private var capturedServerErrorResponseCodes: [Int] = []
    private var threadStartCount = 0
    private var turnStartCount = 0
    private var latestTurnID = "turn_0"
    private var capturedStartCallCount = 0
    private var capturedStopCallCount = 0

    init(
        turnResults: [CodexCompanionMockTurnResult],
        modelListFailuresRemaining: Int = 0,
        failingTurnStartRequestNumbers: Set<Int> = [],
        initializeResponseDelayNanoseconds: UInt64 = 0
    ) {
        self.turnResults = turnResults
        self.modelListFailuresRemaining = modelListFailuresRemaining
        self.failingTurnStartRequestNumbers = failingTurnStartRequestNumbers
        self.initializeResponseDelayNanoseconds =
            initializeResponseDelayNanoseconds
    }

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws {
        stateLock.lock()
        capturedStartCallCount += 1
        messageHandler = onMessage
        terminationHandler = onTermination
        stateLock.unlock()
    }

    func send(_ messageData: Data) throws {
        let incomingMessage = try JSONDecoder().decode(
            CodexAppServerIncomingMessage.self,
            from: messageData
        )
        guard let method = incomingMessage.method else {
            if let errorCode = incomingMessage.error?.code {
                stateLock.lock()
                capturedServerErrorResponseCodes.append(errorCode)
                stateLock.unlock()
            }
            return
        }

        stateLock.lock()
        if let parameters = incomingMessage.params {
            parametersByMethod[method, default: []].append(parameters)
        }
        let methodRequestNumber = parametersByMethod[method]?.count ?? 0
        if method == "turn/start",
           failingTurnStartRequestNumbers.remove(methodRequestNumber) != nil {
            stateLock.unlock()
            throw CodexAppServerError.processTerminated(
                exitCode: -9,
                standardError: "Simulated companion process failure"
            )
        }
        let responseData = try incomingMessage.id.map { requestID in
            try makeResponse(
                method: method,
                requestID: requestID,
                parameters: incomingMessage.params
            )
        }
        let notificationData = method == "turn/start"
            ? try makeLatestTurnNotifications()
            : []
        let currentMessageHandler = messageHandler
        stateLock.unlock()

        if let responseData {
            if method == "initialize",
               initializeResponseDelayNanoseconds > 0 {
                let responseDelayNanoseconds =
                    initializeResponseDelayNanoseconds
                Task {
                    try? await Task.sleep(
                        nanoseconds: responseDelayNanoseconds
                    )
                    currentMessageHandler?(responseData)
                }
            } else {
                currentMessageHandler?(responseData)
            }
        }
        for notification in notificationData {
            currentMessageHandler?(notification)
        }
    }

    func stop() {
        stateLock.lock()
        capturedStopCallCount += 1
        messageHandler = nil
        terminationHandler = nil
        stateLock.unlock()
    }

    var startCallCount: Int {
        stateLock.lock()
        let startCallCount = capturedStartCallCount
        stateLock.unlock()
        return startCallCount
    }

    var stopCallCount: Int {
        stateLock.lock()
        let stopCallCount = capturedStopCallCount
        stateLock.unlock()
        return stopCallCount
    }

    func requestCount(for method: String) -> Int {
        stateLock.lock()
        let requestCount = parametersByMethod[method]?.count ?? 0
        stateLock.unlock()
        return requestCount
    }

    func parameters(for method: String) -> [CodexJSONValue] {
        stateLock.lock()
        let parameters = parametersByMethod[method] ?? []
        stateLock.unlock()
        return parameters
    }

    var serverErrorResponseCount: Int {
        stateLock.lock()
        let responseCount = capturedServerErrorResponseCodes.count
        stateLock.unlock()
        return responseCount
    }

    var serverErrorResponseCodes: [Int] {
        stateLock.lock()
        let responseCodes = capturedServerErrorResponseCodes
        stateLock.unlock()
        return responseCodes
    }

    func emitServerRequest(
        id: CodexAppServerRequestID,
        method: String
    ) throws {
        let requestData = try JSONEncoder().encode(
            CodexAppServerOutgoingRequest(
                method: method,
                id: id,
                params: CodexEmptyParameters()
            )
        )
        stateLock.lock()
        let currentMessageHandler = messageHandler
        stateLock.unlock()
        currentMessageHandler?(requestData)
    }

    func emitTermination(_ error: CodexAppServerError) {
        stateLock.lock()
        let currentTerminationHandler = terminationHandler
        stateLock.unlock()
        currentTerminationHandler?(error)
    }

    private func makeResponse(
        method: String,
        requestID: CodexAppServerRequestID,
        parameters: CodexJSONValue?
    ) throws -> Data {
        switch method {
        case "initialize":
            return try encodeResponse(
                id: requestID,
                result: CodexAppServerInitializeResponse(
                    codexHome: "/tmp/.codex",
                    platformFamily: "unix",
                    platformOs: "macos",
                    userAgent: "codex-test"
                )
            )
        case "account/read":
            return try encodeResponse(
                id: requestID,
                result: CodexAppServerAccountReadResponse(
                    account: CodexAppServerAccount(
                        type: "chatgpt",
                        email: "clicky@example.com",
                        planType: "plus"
                    ),
                    requiresOpenaiAuth: true
                )
            )
        case "model/list":
            if modelListFailuresRemaining > 0 {
                modelListFailuresRemaining -= 1
                return try JSONEncoder().encode(
                    CodexAppServerOutgoingErrorResponse(
                        id: requestID,
                        error: CodexAppServerProtocolError(
                            code: -32001,
                            message: "Temporary model catalog failure",
                            data: nil
                        )
                    )
                )
            }
            return try encodeResponse(
                id: requestID,
                result: CodexModelListResponse(
                    data: [
                        CodexModel(
                            id: "model_other",
                            model: "gpt-other",
                            isDefault: false
                        ),
                        CodexModel(
                            id: "model_default",
                            model: "gpt-default",
                            isDefault: true
                        )
                    ],
                    nextCursor: nil
                )
            )
        case "thread/start":
            threadStartCount += 1
            let threadID = "thread_\(threadStartCount)"
            return try encodeResponse(
                id: requestID,
                result: makeThreadStartResponse(
                    threadID: threadID,
                    parameters: parameters
                )
            )
        case "turn/start":
            turnStartCount += 1
            latestTurnID = "turn_\(turnStartCount)"
            if turnResults.count > 1 {
                latestTurnResult = turnResults.removeFirst()
            } else {
                latestTurnResult = turnResults.first ?? .inProgress
            }
            return try encodeResponse(
                id: requestID,
                result: CodexTurnStartResponse(
                    turn: makeTurn(
                        id: latestTurnID,
                        status: .inProgress,
                        items: [],
                        error: nil
                    )
                )
            )
        case "turn/interrupt":
            return try encodeResponse(
                id: requestID,
                result: CodexEmptyParameters()
            )
        default:
            return try JSONEncoder().encode(
                CodexAppServerOutgoingErrorResponse(
                    id: requestID,
                    error: CodexAppServerProtocolError(
                        code: -32601,
                        message: "Unknown mock method",
                        data: nil
                    )
                )
            )
        }
    }

    private func makeLatestTurnNotifications() throws -> [Data] {
        switch latestTurnResult {
        case .inProgress:
            return []
        case .completed(let responseText):
            let agentMessageItem = makeAgentMessageItem(text: responseText)
            return [
                try encodeNotification(
                    method: "item/completed",
                    parameters: CodexAgentItemCompletedNotification(
                        threadId: "thread_\(threadStartCount)",
                        turnId: latestTurnID,
                        item: agentMessageItem,
                        completedAtMs: 2
                    )
                ),
                try encodeNotification(
                    method: "turn/completed",
                    parameters: CodexTurnLifecycleNotification(
                        threadId: "thread_\(threadStartCount)",
                        turn: makeTurn(
                            id: latestTurnID,
                            status: .completed,
                            items: [],
                            error: nil
                        )
                    )
                )
            ]
        case .completedInTurn(let responseText):
            return [
                try encodeNotification(
                    method: "turn/completed",
                    parameters: CodexTurnLifecycleNotification(
                        threadId: "thread_\(threadStartCount)",
                        turn: makeTurn(
                            id: latestTurnID,
                            status: .completed,
                            items: [makeAgentMessageItem(text: responseText)],
                            error: nil
                        )
                    )
                )
            ]
        case .commentaryThenFinal(let commentary, let finalResponse):
            return [
                try encodeNotification(
                    method: "item/completed",
                    parameters: CodexAgentItemCompletedNotification(
                        threadId: "thread_\(threadStartCount)",
                        turnId: latestTurnID,
                        item: makeAgentMessageItem(
                            text: commentary,
                            phase: "commentary"
                        ),
                        completedAtMs: 2
                    )
                ),
                try encodeNotification(
                    method: "item/completed",
                    parameters: CodexAgentItemCompletedNotification(
                        threadId: "thread_\(threadStartCount)",
                        turnId: latestTurnID,
                        item: makeAgentMessageItem(
                            text: finalResponse,
                            phase: "final_answer"
                        ),
                        completedAtMs: 3
                    )
                ),
                try encodeNotification(
                    method: "turn/completed",
                    parameters: CodexTurnLifecycleNotification(
                        threadId: "thread_\(threadStartCount)",
                        turn: makeTurn(
                            id: latestTurnID,
                            status: .completed,
                            items: [],
                            error: nil
                        )
                    )
                )
            ]
        case .failed(let message):
            return [
                try encodeNotification(
                    method: "turn/completed",
                    parameters: CodexTurnLifecycleNotification(
                        threadId: "thread_\(threadStartCount)",
                        turn: makeTurn(
                            id: latestTurnID,
                            status: .failed,
                            items: [],
                            error: CodexTurnError(
                                message: message,
                                additionalDetails: nil,
                                codexErrorInfo: nil
                            )
                        )
                    )
                )
            ]
        }
    }

    private func makeAgentMessageItem(
        text: String,
        phase: String? = "final_answer"
    ) -> CodexJSONValue {
        var item: [String: CodexJSONValue] = [
            "id": .string("message_\(latestTurnID)"),
            "type": .string("agentMessage"),
            "text": .string(text)
        ]
        if let phase {
            item["phase"] = .string(phase)
        }
        return .object(item)
    }

    private func makeThreadStartResponse(
        threadID: String,
        parameters: CodexJSONValue?
    ) -> CodexThreadStartResponse {
        let parameterObject = objectValue(parameters)
        let model = stringValue(parameterObject?["model"]) ?? "gpt-default"
        let workspacePath = stringValue(parameterObject?["cwd"]) ?? "/tmp"
        return CodexThreadStartResponse(
            thread: makeThread(
                threadID: threadID,
                turns: [],
                workspacePath: workspacePath,
                ephemeral: true
            ),
            model: model,
            modelProvider: "openai",
            cwd: workspacePath,
            approvalPolicy: .string("never"),
            approvalsReviewer: "user",
            sandbox: .object(["type": .string("readOnly")]),
            reasoningEffort: nil,
            instructionSources: []
        )
    }

    private func makeThread(
        threadID: String,
        turns: [CodexTurn],
        workspacePath: String = "/tmp",
        ephemeral: Bool = true
    ) -> CodexThread {
        CodexThread(
            id: threadID,
            sessionId: "session_\(threadID)",
            preview: "",
            name: nil,
            cwd: workspacePath,
            modelProvider: "openai",
            cliVersion: "test",
            createdAt: 1,
            updatedAt: 2,
            ephemeral: ephemeral,
            status: CodexThreadStatus(type: "idle", activeFlags: nil),
            turns: turns
        )
    }

    private func makeTurn(
        id: String,
        status: CodexTurnStatus,
        items: [CodexJSONValue],
        error: CodexTurnError?
    ) -> CodexTurn {
        CodexTurn(
            id: id,
            status: status,
            items: items,
            startedAt: 1,
            completedAt: status == .inProgress ? nil : 2,
            durationMs: status == .inProgress ? nil : 1,
            error: error
        )
    }

    private func encodeResponse<Result: Encodable>(
        id: CodexAppServerRequestID,
        result: Result
    ) throws -> Data {
        try JSONEncoder().encode(
            CodexAppServerOutgoingResponse(
                id: id,
                result: result
            )
        )
    }

    private func encodeNotification<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) throws -> Data {
        try JSONEncoder().encode(
            CodexAppServerOutgoingNotification(
                method: method,
                params: parameters
            )
        )
    }

    private func objectValue(
        _ value: CodexJSONValue?
    ) -> [String: CodexJSONValue]? {
        guard case .object(let objectValue) = value else { return nil }
        return objectValue
    }

    private func stringValue(_ value: CodexJSONValue?) -> String? {
        guard case .string(let stringValue) = value else { return nil }
        return stringValue
    }
}
