import Foundation
import XCTest
@testable import ClickyAgentCore

final class CodexAppServerCoreTests: XCTestCase {
    func testJSONLineFramerPreservesPartialMessagesAndReturnsCompleteLines() {
        var framer = CodexJSONLineFramer()

        XCTAssertTrue(framer.append(Data("{\"id\":1".utf8)).isEmpty)

        let completedLines = framer.append(
            Data("}\n{\"method\":\"turn/started\"}\r\npartial".utf8)
        )

        XCTAssertEqual(
            completedLines.compactMap { String(data: $0, encoding: .utf8) },
            ["{\"id\":1}", "{\"method\":\"turn/started\"}"]
        )
        XCTAssertEqual(
            framer.append(Data("-message\n".utf8)).compactMap { String(data: $0, encoding: .utf8) },
            ["partial-message"]
        )
    }

    func testExecutableOverrideIsTheFirstCandidate() {
        let candidateURLs = CodexExecutableLocator.candidateURLs(
            environment: [
                CodexExecutableLocator.executableOverrideEnvironmentKey: "/tmp/custom-codex"
            ],
            bundleResourceURL: URL(fileURLWithPath: "/tmp/Clicky.app/Contents/Resources")
        )

        XCTAssertEqual(candidateURLs.first?.path, "/tmp/custom-codex")
        XCTAssertEqual(candidateURLs[1].path, "/tmp/Clicky.app/Contents/Resources/codex")
    }

    func testNullResultIsPresentRatherThanMalformed() throws {
        let incomingMessage = try JSONDecoder().decode(
            CodexAppServerIncomingMessage.self,
            from: Data("{\"id\":1,\"result\":null}".utf8)
        )

        XCTAssertTrue(incomingMessage.hasResult)
        XCTAssertEqual(incomingMessage.result, .null)
    }

    func testConnectInitializesBeforeReadingChatGPTAccount() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)

        let session = try await client.connect()

        XCTAssertEqual(session.initialization.platformOs, "macos")
        XCTAssertEqual(session.account.account?.type, "chatgpt")
        XCTAssertEqual(session.account.account?.planType, "plus")
        XCTAssertTrue(session.account.requiresOpenaiAuth)
        XCTAssertTrue(session.account.isAuthenticated)
        XCTAssertTrue(session.account.isUsingChatGPTSubscription)
        XCTAssertEqual(
            transport.sentMethods,
            ["initialize", "initialized", "account/read"]
        )
        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .connected)

        await client.stop()
    }

    func testProtocolErrorsAreReturnedToTheMatchingRequest() async {
        let transport = MockCodexAppServerTransport(accountReadError: true)
        let client = makeClient(transport: transport)

        do {
            _ = try await client.connect()
            XCTFail("Expected account/read to fail")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(
                error,
                .protocolFailure(code: -32000, message: "Account unavailable")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .disconnected)
        XCTAssertTrue(transport.didStop)
    }

    func testRequestTimeoutStopsAnUnresponsiveTransport() async {
        let transport = MockCodexAppServerTransport(ignoreAllRequests: true)
        let client = makeClient(
            transport: transport,
            requestTimeoutNanoseconds: 10_000_000
        )

        do {
            _ = try await client.connect()
            XCTFail("Expected initialize to time out")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .requestTimedOut(method: "initialize"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .disconnected)
        XCTAssertTrue(transport.didStop)
    }

    func testNotificationsAndServerRequestsUseSeparateStreams() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()

        var notificationIterator = client.notifications.makeAsyncIterator()
        var serverRequestIterator = client.serverRequests.makeAsyncIterator()

        transport.emitNotification(
            method: "turn/started",
            params: .object(["turnId": .string("turn_123")])
        )
        transport.emitServerRequest(
            id: .integer(44),
            method: "item/commandExecution/requestApproval",
            params: .object(["command": .string("git status")])
        )

        let notification = await notificationIterator.next()
        let serverRequest = await serverRequestIterator.next()

        XCTAssertEqual(notification?.method, "turn/started")
        XCTAssertEqual(
            notification?.params,
            .object(["turnId": .string("turn_123")])
        )
        XCTAssertEqual(serverRequest?.id, .integer(44))
        XCTAssertEqual(serverRequest?.method, "item/commandExecution/requestApproval")

        try await client.respond(
            to: .integer(44),
            with: ["decision": "decline"]
        )
        XCTAssertEqual(transport.sentResponseIDs, [.integer(44)])

        await client.stop()
    }

    private func makeClient(
        transport: MockCodexAppServerTransport,
        requestTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            transport: transport,
            clientInfo: CodexAppServerClientInfo(
                name: "clicky_tests",
                title: "Clicky Tests",
                version: "1.0"
            ),
            requestTimeoutNanoseconds: requestTimeoutNanoseconds
        )
    }
}

final class CodexAppServerLiveTests: XCTestCase {
    func testAuthenticatedChatGPTCodexHandshake() async throws {
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

        let session = try await client.connect()

        XCTAssertEqual(session.initialization.platformOs, "macos")
        XCTAssertEqual(session.account.account?.type, "chatgpt")
        XCTAssertTrue(session.account.isAuthenticated)
        XCTAssertTrue(session.account.isUsingChatGPTSubscription)

        await client.stop()
    }
}

private final class MockCodexAppServerTransport: CodexAppServerTransport, @unchecked Sendable {
    private let stateLock = NSLock()
    private let accountReadError: Bool
    private let ignoreAllRequests: Bool
    private var messageHandler: (@Sendable (Data) -> Void)?

    private(set) var sentMethods: [String] = []
    private(set) var sentResponseIDs: [CodexAppServerRequestID] = []
    private(set) var didStop = false

    init(
        accountReadError: Bool = false,
        ignoreAllRequests: Bool = false
    ) {
        self.accountReadError = accountReadError
        self.ignoreAllRequests = ignoreAllRequests
    }

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws {
        stateLock.lock()
        messageHandler = onMessage
        didStop = false
        stateLock.unlock()
    }

    func send(_ messageData: Data) throws {
        let incomingMessage = try JSONDecoder().decode(
            CodexAppServerIncomingMessage.self,
            from: messageData
        )

        stateLock.lock()
        if let method = incomingMessage.method {
            sentMethods.append(method)
        } else if let responseID = incomingMessage.id {
            sentResponseIDs.append(responseID)
        }
        let currentMessageHandler = messageHandler
        stateLock.unlock()

        if ignoreAllRequests {
            return
        }

        guard let requestID = incomingMessage.id,
              let method = incomingMessage.method else {
            return
        }

        switch method {
        case "initialize":
            let response = CodexAppServerOutgoingResponse(
                id: requestID,
                result: CodexAppServerInitializeResponse(
                    codexHome: "/tmp/.codex",
                    platformFamily: "unix",
                    platformOs: "macos",
                    userAgent: "codex-test"
                )
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "account/read" where accountReadError:
            let response = CodexAppServerOutgoingErrorResponse(
                id: requestID,
                error: CodexAppServerProtocolError(
                    code: -32000,
                    message: "Account unavailable",
                    data: nil
                )
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "account/read":
            let response = CodexAppServerOutgoingResponse(
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
            currentMessageHandler?(try JSONEncoder().encode(response))
        default:
            break
        }
    }

    func stop() {
        stateLock.lock()
        didStop = true
        messageHandler = nil
        stateLock.unlock()
    }

    func emitNotification(method: String, params: CodexJSONValue) {
        let notification = CodexAppServerOutgoingNotification(
            method: method,
            params: params
        )
        emit(notification)
    }

    func emitServerRequest(
        id: CodexAppServerRequestID,
        method: String,
        params: CodexJSONValue
    ) {
        let request = CodexAppServerOutgoingRequest(
            method: method,
            id: id,
            params: params
        )
        emit(request)
    }

    private func emit<Message: Encodable>(_ message: Message) {
        stateLock.lock()
        let currentMessageHandler = messageHandler
        stateLock.unlock()

        if let encodedMessage = try? JSONEncoder().encode(message) {
            currentMessageHandler?(encodedMessage)
        }
    }
}
