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

    func testJSONLineFramerFinishesAnUnterminatedFinalMessage() {
        var framer = CodexJSONLineFramer()

        XCTAssertTrue(framer.append(Data("{\"method\":\"turn/completed\"}".utf8)).isEmpty)
        XCTAssertEqual(
            framer.finish().flatMap { String(data: $0, encoding: .utf8) },
            "{\"method\":\"turn/completed\"}"
        )
        XCTAssertNil(framer.finish())
    }

    func testChildProcessEnvironmentPreservesAndDeduplicatesPath() {
        let augmentedEnvironment = CodexChildProcessEnvironment.augmentingPath(
            environment: [
                "PATH": "/custom/bin:/opt/homebrew/bin:/custom/bin",
                "CLICKY_TEST_VALUE": "preserved"
            ],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/clicky")
        )

        XCTAssertEqual(augmentedEnvironment["CLICKY_TEST_VALUE"], "preserved")
        XCTAssertEqual(
            augmentedEnvironment["PATH"],
            "/custom/bin:/opt/homebrew/bin:/usr/local/bin:/Users/clicky/.npm-global/bin"
        )
    }

    func testStandardErrorCaptureKeepsOnlyTheBoundedTail() {
        let historicalData = Data("historical-auth-error".utf8)
        let recentData = Data("recent-crash-detail".utf8)

        let capturedData = CodexProcessStandardError.appendingTail(
            recentData,
            to: historicalData,
            maximumByteCount: recentData.count + 3
        )

        XCTAssertEqual(capturedData.count, recentData.count + 3)
        XCTAssertEqual(String(decoding: capturedData.suffix(recentData.count), as: UTF8.self), "recent-crash-detail")
        XCTAssertFalse(String(decoding: capturedData, as: UTF8.self).contains("historical"))
    }

    func testStandardErrorSanitizationRemovesTerminalAndControlSequences() {
        let capturedData = Data(
            "\u{001B}[31mrecent failure\u{001B}[0m\u{0000}\n\u{001B}]0;private title\u{0007}tail".utf8
        )

        XCTAssertEqual(
            CodexProcessStandardError.sanitizedText(from: capturedData),
            "recent failure\ntail"
        )
    }

    func testProcessTerminationDescriptionDoesNotExposeDiagnosticOutput() {
        let error = CodexAppServerError.processTerminated(
            exitCode: 9,
            standardError: "MCP authorization failed for private-account@example.com"
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Codex app-server stopped unexpectedly (status 9)."
        )
        XCTAssertFalse(error.localizedDescription.contains("private-account"))
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

    func testProcessTransportDeliversFinalStandardOutputBeforeTermination() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let executableURL = temporaryDirectoryURL.appendingPathComponent("terminal-message.sh")
        let terminalMessage = "{\"method\":\"turn/completed\"}"
        let script = "#!/bin/sh\nprintf '%s' '\(terminalMessage)'\n"
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let messageExpectation = expectation(description: "final stdout message")
        let terminationExpectation = expectation(description: "process termination")
        let eventRecorder = ProcessTransportEventRecorder()

        let transport = CodexAppServerProcessTransport(executableURL: executableURL)
        try transport.start(
            onMessage: { messageData in
                eventRecorder.recordMessage(messageData)
                messageExpectation.fulfill()
            },
            onTermination: { _ in
                eventRecorder.recordTermination()
                terminationExpectation.fulfill()
            }
        )

        wait(for: [messageExpectation, terminationExpectation], timeout: 5)
        let recordedEvents = eventRecorder.snapshot()

        XCTAssertEqual(recordedEvents.message, terminalMessage)
        XCTAssertEqual(recordedEvents.events, ["message", "termination"])
        transport.stop()
    }

    func testProcessTransportPublishesOnlySanitizedRecentStandardError() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let executableURL = temporaryDirectoryURL.appendingPathComponent("stderr-tail.sh")
        let historicalOutput = "SECRET_OLD_AUTH\n" + String(repeating: "x", count: 5_000)
        let recentOutput = "\u{001B}[31mrecent crash detail\u{001B}[0m"
        let script = "#!/bin/sh\nprintf '%s' '\(historicalOutput)' >&2\nprintf '%s' '\(recentOutput)' >&2\nexit 9\n"
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let terminationExpectation = expectation(description: "sanitized process termination")
        let eventRecorder = ProcessTransportEventRecorder()
        let transport = CodexAppServerProcessTransport(executableURL: executableURL)
        try transport.start(
            onMessage: { _ in },
            onTermination: { error in
                eventRecorder.recordTermination(error)
                terminationExpectation.fulfill()
            }
        )

        wait(for: [terminationExpectation], timeout: 5)
        let recordedError = try XCTUnwrap(eventRecorder.snapshot().terminationError)
        guard case .processTerminated(let exitCode, let standardError) = recordedError else {
            return XCTFail("Expected a process termination error")
        }

        XCTAssertEqual(exitCode, 9)
        XCTAssertFalse(standardError.contains("SECRET_OLD_AUTH"))
        XCTAssertFalse(standardError.contains("\u{001B}"))
        XCTAssertTrue(standardError.hasSuffix("recent crash detail"))
        XCTAssertLessThanOrEqual(standardError.utf8.count, CodexProcessStandardError.maximumCapturedByteCount)
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

    func testChatGPTLoginUsesCodexManagedSubscriptionFlow() async throws {
        let transport = MockCodexAppServerTransport(isSignedOut: true)
        let client = makeClient(transport: transport)
        let session = try await client.connect()

        XCTAssertFalse(session.account.isAuthenticated)
        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .connected)

        let loginResponse = try await client.startChatGPTLogin()

        XCTAssertEqual(loginResponse.type, "chatgpt")
        XCTAssertEqual(loginResponse.loginId, "login_clicky")
        XCTAssertEqual(loginResponse.authUrl, "https://auth.openai.com/codex")
        XCTAssertEqual(transport.sentMethods.last, "account/login/start")
        XCTAssertEqual(
            transport.sentRequestParameters["account/login/start"],
            .object([
                "type": .string("chatgpt"),
                "appBrand": .string("codex"),
                "codexStreamlinedLogin": .boolean(true),
                "useHostedLoginSuccessPage": .boolean(true)
            ])
        )

        await client.stop()
    }

    func testChatGPTLoginCompletionNotificationsPreserveIdentityAndOutcome() async throws {
        let transport = MockCodexAppServerTransport(isSignedOut: true)
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        var completionIterator = client.accountLoginCompletions.makeAsyncIterator()

        transport.emitNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("login_clicky"),
                "success": .boolean(true),
                "error": .null
            ])
        )
        let successfulCompletion = await completionIterator.next()

        XCTAssertEqual(
            successfulCompletion,
            CodexAppServerAccountLoginCompletedNotification(
                loginId: "login_clicky",
                success: true,
                error: nil
            )
        )

        transport.emitNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("login_replacement"),
                "success": .boolean(false),
                "error": .string("Browser login expired")
            ])
        )
        let failedCompletion = await completionIterator.next()

        XCTAssertEqual(
            failedCompletion,
            CodexAppServerAccountLoginCompletedNotification(
                loginId: "login_replacement",
                success: false,
                error: "Browser login expired"
            )
        )

        transport.emitNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .null,
                "success": .boolean(true),
                "error": .null
            ])
        )
        let completionWithoutLoginID = await completionIterator.next()

        XCTAssertEqual(
            completionWithoutLoginID,
            CodexAppServerAccountLoginCompletedNotification(
                loginId: nil,
                success: true,
                error: nil
            )
        )
        XCTAssertTrue(
            CodexAppServerLoginCompletionMatcher.matches(
                try XCTUnwrap(completionWithoutLoginID),
                activeLoginID: "login_clicky",
                allowsMissingLoginID: true
            )
        )
        XCTAssertFalse(
            CodexAppServerLoginCompletionMatcher.matches(
                try XCTUnwrap(completionWithoutLoginID),
                activeLoginID: "login_clicky",
                allowsMissingLoginID: false
            )
        )
        XCTAssertFalse(
            CodexAppServerLoginCompletionMatcher.matches(
                try XCTUnwrap(failedCompletion),
                activeLoginID: "login_clicky",
                allowsMissingLoginID: true
            )
        )
        XCTAssertTrue(
            CodexAppServerLoginCompletionMatcher.matches(
                CodexAppServerAccountLoginCompletedNotification(
                    loginId: "login_clicky",
                    success: true,
                    error: nil
                ),
                activeLoginID: "login_clicky",
                allowsMissingLoginID: false
            )
        )

        await client.stop()
    }

    func testChatGPTLoginCancellationUsesTheStartedLoginIdentity() async throws {
        let transport = MockCodexAppServerTransport(isSignedOut: true)
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        let loginResponse = try await client.startChatGPTLogin()

        let cancellationResponse = try await client.cancelChatGPTLogin(
            loginID: loginResponse.loginId
        )

        XCTAssertEqual(cancellationResponse.status, .canceled)
        XCTAssertEqual(transport.sentMethods.last, "account/login/cancel")
        XCTAssertEqual(
            transport.sentRequestParameters["account/login/cancel"],
            .object(["loginId": .string("login_clicky")])
        )

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

    func testIncomingMessagesPreserveTransportOrder() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()

        var notificationIterator = client.notifications.makeAsyncIterator()
        for messageIndex in 0..<750 {
            transport.emitNotification(
                method: "item/agentMessage/delta",
                params: .object(["sequence": .integer(Int64(messageIndex))])
            )
        }

        var receivedSequence: [Int64] = []
        for _ in 0..<750 {
            let notification = await notificationIterator.next()
            guard case .integer(let messageIndex)? = notification?
                .params?.objectValue?["sequence"] else {
                XCTFail("Expected an integer sequence")
                continue
            }
            receivedSequence.append(messageIndex)
        }

        XCTAssertEqual(receivedSequence, (0..<750).map(Int64.init))
        await client.stop()
    }

    func testUserInputAutoResolutionReturnsEmptyAnswersAfterWindow() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        let store = CodexAgentTaskStore()
        await store.startMonitoring(client: client)

        transport.emitServerRequest(
            id: .integer(51),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread_auto_input"),
                "turnId": .string("turn_auto_input"),
                "itemId": .string("input_auto"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("Scope"),
                        "question": .string("Continue with the safe default?"),
                        "isOther": .boolean(false),
                        "isSecret": .boolean(false),
                        "options": .array([
                            .object([
                                "label": .string("Continue"),
                                "description": .string("Use the safe default.")
                            ])
                        ])
                    ])
                ]),
                "autoResolutionMs": .integer(10)
            ])
        )

        for _ in 0..<100 where !transport.sentResponseIDs.contains(.integer(51)) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(transport.sentResponseIDs.contains(.integer(51)))
        XCTAssertEqual(
            transport.sentResponseResults.last?.objectValue?["answers"],
            .object([:])
        )
        let snapshots = await store.currentSnapshots()
        XCTAssertTrue(snapshots.first?.pendingUserInputs.isEmpty == true)

        await store.stopMonitoring()
        await client.stop()
    }

    func testUnexpectedTransportTerminationPublishesAConnectionFailure() async throws {
        let transport = MockCodexAppServerTransport()
        let client = makeClient(transport: transport)
        _ = try await client.connect()
        var failureIterator = client.failures.makeAsyncIterator()

        let expectedFailure = CodexAppServerError.processTerminated(
            exitCode: 9,
            standardError: "terminated for test"
        )
        transport.emitTermination(expectedFailure)

        let failure = await failureIterator.next()
        XCTAssertEqual(failure, expectedFailure)
        let connectionState = await client.connectionState
        XCTAssertEqual(connectionState, .disconnected)
    }

    func testCoordinatorRejectsFollowUpFromAnotherWorkspace() async throws {
        let transport = MockCodexAppServerTransport()
        let coordinator = CodexAgentCoordinator(
            client: makeClient(transport: transport)
        )
        let task = CodexAgentTaskSnapshot(
            threadID: "thread_workspace",
            turnID: "turn_workspace",
            workspacePath: "/tmp",
            title: "Workspace invariant",
            status: .running,
            latestAgentMessage: "",
            currentActivity: nil,
            activities: [],
            pendingApprovals: [],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 1
        )
        let differentWorkspace = try CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: "/")
        )

        do {
            try await coordinator.followUp(
                prompt: "Continue",
                on: task,
                in: differentWorkspace
            )
            XCTFail("Expected the coordinator to reject a cross-workspace follow-up")
        } catch let error as CodexAgentCoordinatorError {
            XCTAssertEqual(
                error,
                .workspaceMismatch(expectedPath: "/tmp", providedPath: "/")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    func testCoordinatorRefusesFollowUpWhileContextIsCompacting() async throws {
        let transport = MockCodexAppServerTransport()
        let coordinator = CodexAgentCoordinator(
            client: makeClient(transport: transport)
        )
        let task = CodexAgentTaskSnapshot(
            threadID: "thread_compacting",
            turnID: "turn_compacting",
            workspacePath: "/tmp",
            title: "Compacting",
            status: .running,
            latestAgentMessage: "",
            currentActivity: CodexAgentActivity(
                itemID: "compaction_item",
                kind: .contextCompaction,
                summary: "Compacting context",
                status: .running
            ),
            activities: [
                CodexAgentActivity(
                    itemID: "compaction_item",
                    kind: .contextCompaction,
                    summary: "Compacting context",
                    status: .running
                )
            ],
            pendingApprovals: [],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 1
        )
        let workspace = try CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: "/tmp")
        )

        do {
            try await coordinator.followUp(
                prompt: "Continue",
                on: task,
                in: workspace
            )
            XCTFail("Expected the coordinator to refuse follow-up during compaction")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .threadBusyCompacting)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    func testCoordinatorRefreshesCompletedTaskBeforeChoosingFollowUpOperation() async throws {
        let transport = MockCodexAppServerTransport()
        let store = CodexAgentTaskStore()
        let coordinator = CodexAgentCoordinator(
            client: makeClient(transport: transport),
            taskStore: store
        )
        _ = try await coordinator.start()
        defer { Task { await coordinator.stop() } }

        let completedTurn = CodexTurn(
            id: "turn_completed",
            status: .completed,
            items: [],
            startedAt: 1,
            completedAt: 2,
            durationMs: 1,
            error: nil
        )
        await store.register(
            thread: CodexThread(
                id: "thread_completed",
                sessionId: "session_completed",
                preview: "Completed task",
                name: nil,
                cwd: "/tmp",
                modelProvider: "openai",
                cliVersion: "0.144.2",
                createdAt: 1,
                updatedAt: 2,
                ephemeral: false,
                status: CodexThreadStatus(type: "idle", activeFlags: nil),
                turns: [completedTurn]
            )
        )
        let staleRunningTask = CodexAgentTaskSnapshot(
            threadID: "thread_completed",
            turnID: "turn_completed",
            workspacePath: "/tmp",
            title: "Completed task",
            status: .running,
            latestAgentMessage: "",
            currentActivity: nil,
            activities: [],
            pendingApprovals: [],
            pendingUserInputs: [],
            errorMessage: nil,
            lastEventSequence: 1
        )
        let workspace = try CodexAgentWorkspace(
            directoryURL: URL(fileURLWithPath: "/tmp")
        )

        try await coordinator.followUp(
            prompt: "Add a regression test",
            on: staleRunningTask,
            in: workspace
        )

        XCTAssertEqual(
            Array(transport.sentMethods.suffix(2)),
            ["thread/resume", "turn/start"]
        )
        XCTAssertFalse(transport.sentMethods.contains("turn/steer"))
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

private final class ProcessTransportEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    private var events: [String] = []
    private var terminationError: CodexAppServerError?

    func recordMessage(_ messageData: Data) {
        lock.lock()
        message = String(data: messageData, encoding: .utf8)
        events.append("message")
        lock.unlock()
    }

    func recordTermination(_ error: CodexAppServerError? = nil) {
        lock.lock()
        terminationError = error
        events.append("termination")
        lock.unlock()
    }

    func snapshot() -> (
        message: String?,
        events: [String],
        terminationError: CodexAppServerError?
    ) {
        lock.lock()
        let snapshot = (
            message: message,
            events: events,
            terminationError: terminationError
        )
        lock.unlock()
        return snapshot
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
    private let holdFirstInitializeResponse: Bool
    private let isSignedOut: Bool
    private var messageHandler: (@Sendable (Data) -> Void)?
    private var terminationHandler: (@Sendable (CodexAppServerError) -> Void)?
    private var previousTerminationHandler: (@Sendable (CodexAppServerError) -> Void)?
    private var nextStopHandler: (@Sendable () -> Void)?
    private var storedInitializeRequestCount = 0

    private(set) var sentMethods: [String] = []
    private(set) var sentRequestParameters: [String: CodexJSONValue] = [:]
    private(set) var sentResponseIDs: [CodexAppServerRequestID] = []
    private(set) var sentResponseResults: [CodexJSONValue] = []
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
        holdFirstInitializeResponse: Bool = false,
        isSignedOut: Bool = false
    ) {
        self.accountReadError = accountReadError
        self.ignoreAllRequests = ignoreAllRequests
        self.holdFirstInitializeResponse = holdFirstInitializeResponse
        self.isSignedOut = isSignedOut
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
            if let parameters = incomingMessage.params {
                sentRequestParameters[method] = parameters
            }
        } else if let responseID = incomingMessage.id {
            sentResponseIDs.append(responseID)
            if let responseResult = incomingMessage.result {
                sentResponseResults.append(responseResult)
            }
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
                    account: isSignedOut
                        ? nil
                        : CodexAppServerAccount(
                            type: "chatgpt",
                            email: "clicky@example.com",
                            planType: "plus"
                        ),
                    requiresOpenaiAuth: true
                )
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "account/login/start":
            let response = CodexAppServerOutgoingResponse(
                id: requestID,
                result: CodexAppServerChatGPTLoginResponse(
                    type: "chatgpt",
                    loginId: "login_clicky",
                    authUrl: "https://auth.openai.com/codex"
                )
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "account/login/cancel":
            let response = CodexAppServerOutgoingResponse(
                id: requestID,
                result: CodexAppServerCancelLoginResponse(status: .canceled)
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "thread/resume":
            let response = CodexAppServerOutgoingResponse(
                id: requestID,
                result: CodexThreadStartResponse(
                    thread: CodexThread(
                        id: "thread_completed",
                        sessionId: "session_completed",
                        preview: "Completed task",
                        name: nil,
                        cwd: "/tmp",
                        modelProvider: "openai",
                        cliVersion: "0.144.2",
                        createdAt: 1,
                        updatedAt: 2,
                        ephemeral: false,
                        status: CodexThreadStatus(type: "idle", activeFlags: nil),
                        turns: []
                    ),
                    model: "gpt-5",
                    modelProvider: "openai",
                    cwd: "/tmp",
                    approvalPolicy: .string("on-request"),
                    approvalsReviewer: "user",
                    sandbox: .string("workspace-write"),
                    reasoningEffort: nil,
                    instructionSources: nil
                )
            )
            currentMessageHandler?(try JSONEncoder().encode(response))
        case "turn/start":
            let response = CodexAppServerOutgoingResponse(
                id: requestID,
                result: CodexTurnStartResponse(
                    turn: CodexTurn(
                        id: "turn_follow_up",
                        status: .inProgress,
                        items: [],
                        startedAt: 3,
                        completedAt: nil,
                        durationMs: nil,
                        error: nil
                    )
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

    func emitTermination(_ error: CodexAppServerError) {
        stateLock.lock()
        let currentTerminationHandler = terminationHandler
        stateLock.unlock()
        currentTerminationHandler?(error)
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
