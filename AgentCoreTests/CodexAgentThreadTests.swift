import Foundation
import XCTest
@testable import ClickyAgentCore

final class CodexAgentThreadTests: XCTestCase {
    func testWorkspaceMustBeAnExistingDirectory() throws {
        let missingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try CodexAgentWorkspace(directoryURL: missingDirectoryURL)
        )

        let packageFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.swift")
        XCTAssertThrowsError(
            try CodexAgentWorkspace(directoryURL: packageFileURL)
        )
    }

    func testThreadStartAndResumeAlwaysReassertSafeWorkspaceDefaults() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        let workspace = try currentWorkspace()
        _ = try await client.connect()

        let startedThread = try await client.startThread(
            in: workspace,
            model: "  gpt-5.4  ",
            developerInstructions: "  Keep changes scoped.  "
        )
        _ = try await client.resumeThread(
            threadID: startedThread.thread.id,
            in: workspace,
            model: "  gpt-5.4  "
        )

        let startParameters = try parametersObject(
            transport.lastParameters(for: "thread/start")
        )
        XCTAssertEqual(startParameters["cwd"], .string(workspace.path))
        XCTAssertEqual(startParameters["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(startParameters["approvalsReviewer"], .string("user"))
        XCTAssertEqual(startParameters["sandbox"], .string("workspace-write"))
        XCTAssertEqual(startParameters["ephemeral"], .boolean(false))
        XCTAssertEqual(startParameters["model"], .string("gpt-5.4"))
        XCTAssertEqual(
            startParameters["developerInstructions"],
            .string("Keep changes scoped.")
        )

        let resumeParameters = try parametersObject(
            transport.lastParameters(for: "thread/resume")
        )
        XCTAssertEqual(resumeParameters["threadId"], .string(startedThread.thread.id))
        XCTAssertEqual(resumeParameters["cwd"], .string(workspace.path))
        XCTAssertEqual(resumeParameters["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(resumeParameters["sandbox"], .string("workspace-write"))
        XCTAssertEqual(resumeParameters["model"], .string("gpt-5.4"))

        await client.stop()
    }

    func testThreadListAndReadAreScopedAndIncludeDurableHistory() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        let workspace = try currentWorkspace()
        _ = try await client.connect()

        let listedThreads = try await client.listThreads(in: workspace)
        let readThread = try await client.readThread(
            threadID: listedThreads.data[0].id,
            in: workspace
        )

        XCTAssertEqual(listedThreads.data.count, 1)
        XCTAssertEqual(readThread.thread.turns.first?.status, .completed)

        let listParameters = try parametersObject(
            transport.lastParameters(for: "thread/list")
        )
        XCTAssertEqual(listParameters["cwd"], .array([.string(workspace.path)]))
        XCTAssertEqual(listParameters["limit"], .integer(50))
        XCTAssertEqual(listParameters["sortKey"], .string("updated_at"))
        XCTAssertEqual(listParameters["sortDirection"], .string("desc"))

        let readParameters = try parametersObject(
            transport.lastParameters(for: "thread/read")
        )
        XCTAssertEqual(readParameters["includeTurns"], .boolean(true))

        await client.stop()
    }

    func testTurnStartTrimsPromptAndReassertsWorkspaceSandbox() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        let workspace = try currentWorkspace()
        _ = try await client.connect()

        let startedTurn = try await client.startTurn(
            threadID: "thread_123",
            prompt: "  Inspect the repository.  ",
            in: workspace,
            reasoningEffort: "  high  ",
            clientUserMessageID: "message_123"
        )

        XCTAssertEqual(startedTurn.turn.status, .inProgress)

        let turnParameters = try parametersObject(
            transport.lastParameters(for: "turn/start")
        )
        XCTAssertEqual(turnParameters["cwd"], .string(workspace.path))
        XCTAssertEqual(turnParameters["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(turnParameters["approvalsReviewer"], .string("user"))
        XCTAssertEqual(turnParameters["effort"], .string("high"))
        XCTAssertEqual(turnParameters["clientUserMessageId"], .string("message_123"))

        let inputValues = try arrayValue(turnParameters["input"])
        let textInput = try parametersObject(inputValues.first)
        XCTAssertEqual(textInput["type"], .string("text"))
        XCTAssertEqual(textInput["text"], .string("Inspect the repository."))

        let sandboxPolicy = try parametersObject(turnParameters["sandboxPolicy"])
        XCTAssertEqual(sandboxPolicy["type"], .string("workspaceWrite"))
        XCTAssertEqual(sandboxPolicy["writableRoots"], .array([.string(workspace.path)]))
        XCTAssertEqual(sandboxPolicy["networkAccess"], .boolean(false))
        XCTAssertEqual(sandboxPolicy["excludeSlashTmp"], .boolean(true))
        XCTAssertEqual(sandboxPolicy["excludeTmpdirEnvVar"], .boolean(true))

        await client.stop()
    }

    func testReadThreadRejectsAThreadFromAnotherWorkspace() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()

        // The mock's thread/read always answers with a thread rooted in the
        // current directory, so a workspace pointing anywhere else must be
        // rejected by the client's scoping guard.
        let otherDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: otherDirectoryURL) }
        let otherWorkspace = try CodexAgentWorkspace(directoryURL: otherDirectoryURL)

        do {
            _ = try await client.readThread(threadID: "thread_123", in: otherWorkspace)
            XCTFail("Expected readThread to reject a thread outside the workspace")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(
                error,
                .threadOutsideWorkspace(
                    threadID: "thread_123",
                    workspacePath: otherWorkspace.path
                )
            )
        }

        await client.stop()
    }

    func testEmptyPromptFailsBeforeSendingATurn() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        let workspace = try currentWorkspace()
        _ = try await client.connect()

        do {
            _ = try await client.startTurn(
                threadID: "thread_123",
                prompt: "  \n  ",
                in: workspace
            )
            XCTFail("Expected an empty prompt to fail")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .emptyAgentPrompt)
        }

        XCTAssertNil(transport.lastParameters(for: "turn/start"))
        await client.stop()
    }

    func testSteerAndInterruptTargetTheExpectedActiveTurn() async throws {
        let transport = AgentThreadMockTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()

        let steerResponse = try await client.steerTurn(
            threadID: "thread_123",
            expectedTurnID: "turn_123",
            prompt: "Focus on the tests.",
            clientUserMessageID: "message_steer"
        )
        try await client.interruptTurn(
            threadID: "thread_123",
            turnID: steerResponse.turnId
        )

        let steerParameters = try parametersObject(
            transport.lastParameters(for: "turn/steer")
        )
        XCTAssertEqual(steerParameters["expectedTurnId"], .string("turn_123"))

        let interruptParameters = try parametersObject(
            transport.lastParameters(for: "turn/interrupt")
        )
        XCTAssertEqual(interruptParameters["threadId"], .string("thread_123"))
        XCTAssertEqual(interruptParameters["turnId"], .string("turn_123"))

        await client.stop()
    }

    func testTurnLifecycleNotificationDecodesFromDynamicParameters() throws {
        let notificationParameters = CodexTurnLifecycleNotification(
            threadId: "thread_123",
            turn: AgentThreadMockTransport.makeTurn(status: .completed)
        )
        let encodedParameters = try JSONEncoder().encode(notificationParameters)
        let dynamicParameters = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: encodedParameters
        )
        let notification = CodexAppServerNotification(
            method: "turn/completed",
            params: dynamicParameters
        )

        let decodedParameters = try notification.decodeParameters(
            as: CodexTurnLifecycleNotification.self
        )

        XCTAssertEqual(decodedParameters, notificationParameters)
    }

    private func makeClient(
        transport: AgentThreadMockTransport
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            transport: transport,
            clientInfo: CodexAppServerClientInfo(
                name: "clicky_agent_tests",
                title: "Clicky Agent Tests",
                version: "1.0"
            )
        )
    }

    private func currentWorkspace() throws -> CodexAgentWorkspace {
        try CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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

extension CodexAppServerLiveTests {
    func testEphemeralThreadUsesSelectedWorkspaceAndSafeDefaults() async throws {
        guard ProcessInfo.processInfo.environment["CLICKY_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set CLICKY_RUN_CODEX_INTEGRATION_TESTS=1 to exercise the installed Codex app-server")
        }

        let executablePath = ProcessInfo.processInfo.environment["CLICKY_CODEX_EXECUTABLE"]
            ?? "/Applications/ChatGPT.app/Contents/Resources/codex"
        let client = try CodexAppServerClient.makeLive(
            environment: [
                CodexExecutableLocator.executableOverrideEnvironmentKey: executablePath
            ],
            bundleResourceURL: nil,
            clientVersion: "integration-test"
        )
        let workspace = try CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )

        _ = try await client.connect()
        let startedThread = try await client.startThread(
            in: workspace,
            ephemeral: true
        )

        XCTAssertTrue(startedThread.thread.ephemeral)
        XCTAssertEqual(startedThread.thread.cwd, workspace.path)
        XCTAssertEqual(startedThread.approvalPolicy, .string("on-request"))

        await client.stop()
    }
}

private final class AgentThreadMockTransport: CodexAppServerTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var sentParametersByMethod: [String: [CodexJSONValue?]] = [:]

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws {
        stateLock.lock()
        messageHandler = onMessage
        stateLock.unlock()
    }

    func send(_ messageData: Data) throws {
        let incomingMessage = try JSONDecoder().decode(
            CodexAppServerIncomingMessage.self,
            from: messageData
        )

        guard let method = incomingMessage.method else { return }

        stateLock.lock()
        sentParametersByMethod[method, default: []].append(incomingMessage.params)
        let currentMessageHandler = messageHandler
        stateLock.unlock()

        guard let requestID = incomingMessage.id else { return }

        let responseData = try responseData(
            for: method,
            requestID: requestID,
            parameters: incomingMessage.params
        )
        currentMessageHandler?(responseData)
    }

    func stop() {
        stateLock.lock()
        messageHandler = nil
        stateLock.unlock()
    }

    func lastParameters(for method: String) -> CodexJSONValue? {
        stateLock.lock()
        let parameters = sentParametersByMethod[method]?.last ?? nil
        stateLock.unlock()
        return parameters
    }

    private func responseData(
        for method: String,
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
        case "thread/start", "thread/resume":
            let parametersObject = Self.objectValue(parameters)
            let workspacePath = Self.stringValue(parametersObject?["cwd"])
                ?? FileManager.default.currentDirectoryPath
            let ephemeral = Self.booleanValue(parametersObject?["ephemeral"]) ?? false
            return try encodeResponse(
                id: requestID,
                result: Self.makeThreadStartResponse(
                    workspacePath: workspacePath,
                    ephemeral: ephemeral
                )
            )
        case "thread/list":
            let workspacePath = Self.firstStringValue(
                Self.objectValue(parameters)?["cwd"]
            ) ?? FileManager.default.currentDirectoryPath
            return try encodeResponse(
                id: requestID,
                result: CodexThreadListResponse(
                    data: [Self.makeThread(workspacePath: workspacePath)],
                    nextCursor: nil,
                    backwardsCursor: nil
                )
            )
        case "thread/read":
            var thread = Self.makeThread(
                workspacePath: FileManager.default.currentDirectoryPath
            )
            thread = CodexThread(
                id: thread.id,
                sessionId: thread.sessionId,
                preview: thread.preview,
                name: thread.name,
                cwd: thread.cwd,
                modelProvider: thread.modelProvider,
                cliVersion: thread.cliVersion,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt,
                ephemeral: thread.ephemeral,
                status: thread.status,
                turns: [Self.makeTurn(status: .completed)]
            )
            return try encodeResponse(
                id: requestID,
                result: CodexThreadReadResponse(thread: thread)
            )
        case "turn/start":
            return try encodeResponse(
                id: requestID,
                result: CodexTurnStartResponse(
                    turn: Self.makeTurn(status: .inProgress)
                )
            )
        case "turn/steer":
            return try encodeResponse(
                id: requestID,
                result: CodexTurnSteerResponse(turnId: "turn_123")
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

    private func encodeResponse<Result: Encodable>(
        id: CodexAppServerRequestID,
        result: Result
    ) throws -> Data {
        try JSONEncoder().encode(
            CodexAppServerOutgoingResponse(id: id, result: result)
        )
    }

    static func makeTurn(status: CodexTurnStatus) -> CodexTurn {
        CodexTurn(
            id: "turn_123",
            status: status,
            items: [],
            startedAt: 1,
            completedAt: status == .inProgress ? nil : 2,
            durationMs: status == .inProgress ? nil : 1_000,
            error: nil
        )
    }

    private static func makeThreadStartResponse(
        workspacePath: String,
        ephemeral: Bool
    ) -> CodexThreadStartResponse {
        CodexThreadStartResponse(
            thread: makeThread(
                workspacePath: workspacePath,
                ephemeral: ephemeral
            ),
            model: "gpt-5.4",
            modelProvider: "openai",
            cwd: workspacePath,
            approvalPolicy: .string("on-request"),
            approvalsReviewer: "user",
            sandbox: .object(["type": .string("workspaceWrite")]),
            reasoningEffort: "high",
            instructionSources: []
        )
    }

    private static func makeThread(
        workspacePath: String,
        ephemeral: Bool = false
    ) -> CodexThread {
        CodexThread(
            id: "thread_123",
            sessionId: "session_123",
            preview: "Inspect the repository.",
            name: nil,
            cwd: workspacePath,
            modelProvider: "openai",
            cliVersion: "0.144.2",
            createdAt: 1,
            updatedAt: 2,
            ephemeral: ephemeral,
            status: CodexThreadStatus(type: "idle", activeFlags: nil),
            turns: []
        )
    }

    private static func objectValue(
        _ value: CodexJSONValue?
    ) -> [String: CodexJSONValue]? {
        guard case .object(let objectValue) = value else { return nil }
        return objectValue
    }

    private static func stringValue(_ value: CodexJSONValue?) -> String? {
        guard case .string(let stringValue) = value else { return nil }
        return stringValue
    }

    private static func booleanValue(_ value: CodexJSONValue?) -> Bool? {
        guard case .boolean(let booleanValue) = value else { return nil }
        return booleanValue
    }

    private static func firstStringValue(_ value: CodexJSONValue?) -> String? {
        guard case .array(let arrayValue) = value else { return nil }
        return stringValue(arrayValue.first)
    }
}
