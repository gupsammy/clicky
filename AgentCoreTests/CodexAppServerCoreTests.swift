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

    func testProcessTransportIgnoresTerminationFromStoppedProcessAfterRestart() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let executableURL = temporaryDirectoryURL.appendingPathComponent("delayed-exit.sh")
        let processReadySentinelURL = temporaryDirectoryURL
            .appendingPathComponent("process-ready")
        let stoppedProcessSentinelURL = temporaryDirectoryURL
            .appendingPathComponent("stopped-process-terminated")
        let script = """
        #!/bin/sh
        process_ready_sentinel="$(dirname "$0")/process-ready"
        stopped_process_sentinel="$(dirname "$0")/stopped-process-terminated"
        trap '' TERM
        touch "$process_ready_sentinel"
        cat >/dev/null
        sleep 0.2
        touch "$stopped_process_sentinel"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let transport = CodexAppServerProcessTransport(executableURL: executableURL)
        try transport.start(onMessage: { _ in }, onTermination: { _ in })

        let processReadyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: processReadySentinelURL.path),
              Date() < processReadyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: processReadySentinelURL.path) else {
            transport.stop()
            return XCTFail("The first process did not become ready before the deadline")
        }

        transport.stop()
        try transport.start(onMessage: { _ in }, onTermination: { _ in })

        let stoppedProcessDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: stoppedProcessSentinelURL.path),
              Date() < stoppedProcessDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard FileManager.default.fileExists(atPath: stoppedProcessSentinelURL.path) else {
            transport.stop()
            return XCTFail("The stopped process did not terminate before the deadline")
        }

        for _ in 0..<50 {
            XCTAssertNoThrow(try transport.send(Data("{}".utf8)))
            Thread.sleep(forTimeInterval: 0.01)
        }
        transport.stop()
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

    func testTransportMessagesAreReducedInDeliveryOrder() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        for sequenceNumber in 1...40 {
            transport.emitNotification(
                method: "test/ordered",
                params: .object(["sequence": .integer(Int64(sequenceNumber))])
            )
        }

        let notifications = try await collectNotifications(
            from: client.notifications,
            count: 40
        )
        let receivedSequenceNumbers = notifications.compactMap { notification -> Int64? in
            guard case .object(let parameters) = notification.params,
                  case .integer(let sequenceNumber) = parameters["sequence"] else {
                return nil
            }
            return sequenceNumber
        }

        XCTAssertEqual(receivedSequenceNumbers, Array(1...40).map(Int64.init))
        await client.stop()
    }

    func testStaleTransportTerminationCannotDisconnectAReconnectedClient() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        await client.stop()
        _ = try await client.connect()

        transport.emitPreviousTermination(
            .processTerminated(exitCode: 15, standardError: "stopped session")
        )
        transport.emitNotification(
            method: "test/current-session",
            params: .object(["session": .string("current")])
        )

        let notifications = try await collectNotifications(
            from: client.notifications,
            count: 1
        )
        XCTAssertEqual(notifications.first?.method, "test/current-session")
        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .connected)
        do {
            try await client.respond(
                to: .integer(99),
                with: ["decision": "accept"]
            )
        } catch {
            XCTFail("Expected the reconnected client to remain usable: \(error)")
        }

        await client.stop()
    }

    func testSupersededConnectFailureCannotStopANewerConnection() async throws {
        let transport = MockCodexAppServerTransport(holdFirstInitializeResponse: true)
        let client = makeClient(transport: transport)
        let reconnectResultStreamPair = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        transport.setNextStopHandler {
            Task(priority: .high) {
                do {
                    _ = try await client.connect()
                    reconnectResultStreamPair.continuation.yield(true)
                } catch {
                    reconnectResultStreamPair.continuation.yield(false)
                }
            }
        }

        let supersededConnectionTask = Task(priority: .background) {
            try? await client.connect()
        }

        let initializeRequestDeadline = Date().addingTimeInterval(2)
        while transport.initializeRequestCount < 1,
              Date() < initializeRequestDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard transport.initializeRequestCount == 1 else {
            await client.stop()
            return XCTFail("The first connection did not reach its suspended handshake")
        }

        await client.stop()
        let reconnectSucceeded = try await firstValue(from: reconnectResultStreamPair.stream)
        XCTAssertTrue(reconnectSucceeded)
        _ = await supersededConnectionTask.value

        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .connected)
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

    private func collectNotifications(
        from notifications: AsyncStream<CodexAppServerNotification>,
        count: Int,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> [CodexAppServerNotification] {
        try await withThrowingTaskGroup(of: [CodexAppServerNotification].self) { taskGroup in
            taskGroup.addTask {
                var notificationIterator = notifications.makeAsyncIterator()
                var collectedNotifications: [CodexAppServerNotification] = []
                while collectedNotifications.count < count,
                      let notification = await notificationIterator.next() {
                    collectedNotifications.append(notification)
                }
                return collectedNotifications
            }
            taskGroup.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NotificationCollectionTimeoutError()
            }

            defer { taskGroup.cancelAll() }
            guard let collectedNotifications = try await taskGroup.next() else {
                throw NotificationCollectionTimeoutError()
            }
            return collectedNotifications
        }
    }

    private func firstValue<Element: Sendable>(
        from stream: AsyncStream<Element>,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { taskGroup in
            taskGroup.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else {
                    throw NotificationCollectionTimeoutError()
                }
                return value
            }
            taskGroup.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NotificationCollectionTimeoutError()
            }

            defer { taskGroup.cancelAll() }
            guard let value = try await taskGroup.next() else {
                throw NotificationCollectionTimeoutError()
            }
            return value
        }
    }
}

private struct NotificationCollectionTimeoutError: Error {}

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
    private let holdFirstInitializeResponse: Bool
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var terminationHandler: (@Sendable (CodexAppServerError) -> Void)?
    private var previousTerminationHandler: (@Sendable (CodexAppServerError) -> Void)?
    private var nextStopHandler: (@Sendable () -> Void)?
    private var storedInitializeRequestCount = 0

    private(set) var sentMethods: [String] = []
    private(set) var sentResponseIDs: [CodexAppServerRequestID] = []
    private(set) var didStop = false

    var initializeRequestCount: Int {
        stateLock.lock()
        let initializeRequestCount = storedInitializeRequestCount
        stateLock.unlock()
        return initializeRequestCount
    }

    init(
        accountReadError: Bool = false,
        ignoreAllRequests: Bool = false,
        holdFirstInitializeResponse: Bool = false
    ) {
        self.accountReadError = accountReadError
        self.ignoreAllRequests = ignoreAllRequests
        self.holdFirstInitializeResponse = holdFirstInitializeResponse
    }

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onTermination: @escaping @Sendable (CodexAppServerError) -> Void
    ) throws {
        stateLock.lock()
        messageHandler = onMessage
        terminationHandler = onTermination
        didStop = false
        stateLock.unlock()
    }

    func send(_ messageData: Data) throws {
        let incomingMessage = try JSONDecoder().decode(
            CodexAppServerIncomingMessage.self,
            from: messageData
        )

        stateLock.lock()
        var shouldHoldInitializeResponse = false
        if let method = incomingMessage.method {
            sentMethods.append(method)
            if method == "initialize" {
                storedInitializeRequestCount += 1
                shouldHoldInitializeResponse = holdFirstInitializeResponse
                    && storedInitializeRequestCount == 1
            }
        } else if let responseID = incomingMessage.id {
            sentResponseIDs.append(responseID)
        }
        let currentMessageHandler = messageHandler
        stateLock.unlock()

        if ignoreAllRequests || shouldHoldInitializeResponse {
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
        previousTerminationHandler = terminationHandler
        messageHandler = nil
        terminationHandler = nil
        let nextStopHandler = nextStopHandler
        self.nextStopHandler = nil
        stateLock.unlock()
        nextStopHandler?()
    }

    func setNextStopHandler(_ nextStopHandler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        self.nextStopHandler = nextStopHandler
        stateLock.unlock()
    }

    func emitPreviousTermination(_ error: CodexAppServerError) {
        stateLock.lock()
        let previousTerminationHandler = previousTerminationHandler
        stateLock.unlock()
        previousTerminationHandler?(error)
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
