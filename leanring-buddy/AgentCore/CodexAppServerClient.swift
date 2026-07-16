//
//  CodexAppServerClient.swift
//  leanring-buddy
//
//  Correlates app-server requests and exposes streamed server events.
//

import Foundation

actor CodexAppServerClient {
    nonisolated let notifications: AsyncStream<CodexAppServerNotification>
    nonisolated let serverRequests: AsyncStream<CodexAppServerRequest>

    private enum TransportEvent: Sendable {
        case message(generation: UInt64, data: Data)
        case termination(generation: UInt64, error: CodexAppServerError)

        var generation: UInt64 {
            switch self {
            case .message(let generation, _), .termination(let generation, _):
                return generation
            }
        }
    }

    private let transport: CodexAppServerTransport
    private let clientInfo: CodexAppServerClientInfo
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let notificationContinuation: AsyncStream<CodexAppServerNotification>.Continuation
    private let serverRequestContinuation: AsyncStream<CodexAppServerRequest>.Continuation
    private let transportEvents: AsyncStream<TransportEvent>
    private let transportEventContinuation: AsyncStream<TransportEvent>.Continuation
    private let requestTimeoutNanoseconds: UInt64
    private var transportEventMonitoringTask: Task<Void, Never>?

    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var nextRequestID: Int64 = 1
    private var pendingRequests: [CodexAppServerRequestID: PendingRequest] = [:]
    private var nextTransportGeneration: UInt64 = 1
    private var activeTransportGeneration: UInt64?

    private(set) var connectionState: CodexAppServerConnectionState = .disconnected

    init(
        transport: CodexAppServerTransport,
        clientInfo: CodexAppServerClientInfo,
        requestTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) {
        let notificationStreamPair = AsyncStream<CodexAppServerNotification>.makeStream(
            bufferingPolicy: .bufferingNewest(500)
        )
        let serverRequestStreamPair = AsyncStream<CodexAppServerRequest>.makeStream(
            bufferingPolicy: .unbounded
        )
        let transportEventStreamPair = AsyncStream<TransportEvent>.makeStream(
            bufferingPolicy: .unbounded
        )

        self.transport = transport
        self.clientInfo = clientInfo
        self.notifications = notificationStreamPair.stream
        self.notificationContinuation = notificationStreamPair.continuation
        self.serverRequests = serverRequestStreamPair.stream
        self.serverRequestContinuation = serverRequestStreamPair.continuation
        self.transportEvents = transportEventStreamPair.stream
        self.transportEventContinuation = transportEventStreamPair.continuation
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    deinit {
        transportEventMonitoringTask?.cancel()
        transport.stop()
        notificationContinuation.finish()
        serverRequestContinuation.finish()
        transportEventContinuation.finish()
    }

    static func makeLive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        clientVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    ) throws -> CodexAppServerClient {
        guard let executableURL = CodexExecutableLocator.locate(
            environment: environment,
            bundleResourceURL: bundleResourceURL
        ) else {
            throw CodexAppServerError.executableNotFound
        }

        return CodexAppServerClient(
            transport: CodexAppServerProcessTransport(executableURL: executableURL),
            clientInfo: CodexAppServerClientInfo(
                name: "clicky_macos",
                title: "Clicky",
                version: clientVersion
            )
        )
    }

    func connect() async throws -> CodexAppServerSession {
        guard connectionState == .disconnected else {
            throw CodexAppServerError.alreadyConnected
        }

        connectionState = .connecting
        let transportGeneration = nextTransportGeneration
        nextTransportGeneration &+= 1
        activeTransportGeneration = transportGeneration
        startMonitoringTransportEventsIfNeeded()

        do {
            try transport.start(
                onMessage: { [transportEventContinuation] messageData in
                    transportEventContinuation.yield(
                        .message(generation: transportGeneration, data: messageData)
                    )
                },
                onTermination: { [transportEventContinuation] terminationError in
                    transportEventContinuation.yield(
                        .termination(generation: transportGeneration, error: terminationError)
                    )
                }
            )

            let initializationResponse: CodexAppServerInitializeResponse = try await sendRequest(
                method: "initialize",
                parameters: CodexAppServerInitializeParameters(
                    clientInfo: clientInfo,
                    capabilities: CodexAppServerInitializeCapabilities()
                )
            )

            try sendNotification(
                method: "initialized",
                parameters: CodexEmptyParameters()
            )

            let accountResponse: CodexAppServerAccountReadResponse = try await sendRequest(
                method: "account/read",
                parameters: CodexAppServerAccountReadParameters()
            )

            guard activeTransportGeneration == transportGeneration else {
                throw CodexAppServerError.notConnected
            }
            connectionState = .connected
            return CodexAppServerSession(
                initialization: initializationResponse,
                account: accountResponse
            )
        } catch {
            if activeTransportGeneration == transportGeneration {
                activeTransportGeneration = nil
            }
            failPendingRequests(with: error)
            transport.stop()
            connectionState = .disconnected
            throw error
        }
    }

    func refreshAccount() async throws -> CodexAppServerAccountReadResponse {
        guard connectionState == .connected else {
            throw CodexAppServerError.notConnected
        }

        return try await sendRequest(
            method: "account/read",
            parameters: CodexAppServerAccountReadParameters(refreshToken: true)
        )
    }

    func respond<Response: Encodable>(
        to requestID: CodexAppServerRequestID,
        with response: Response
    ) throws {
        guard connectionState == .connected else {
            throw CodexAppServerError.notConnected
        }

        let outgoingResponse = CodexAppServerOutgoingResponse(
            id: requestID,
            result: response
        )
        try transport.send(jsonEncoder.encode(outgoingResponse))
    }

    func respondWithError(
        to requestID: CodexAppServerRequestID,
        code: Int,
        message: String
    ) throws {
        guard connectionState == .connected else {
            throw CodexAppServerError.notConnected
        }

        let outgoingResponse = CodexAppServerOutgoingErrorResponse(
            id: requestID,
            error: CodexAppServerProtocolError(
                code: code,
                message: message,
                data: nil
            )
        )
        try transport.send(jsonEncoder.encode(outgoingResponse))
    }

    func stop() {
        guard connectionState != .disconnected else { return }

        activeTransportGeneration = nil
        transport.stop()
        failPendingRequests(with: CodexAppServerError.notConnected)
        connectionState = .disconnected
    }

    private func sendRequest<Parameters: Encodable, Response: Decodable>(
        method: String,
        parameters: Parameters
    ) async throws -> Response {
        guard connectionState != .disconnected else {
            throw CodexAppServerError.notConnected
        }

        let requestID = CodexAppServerRequestID.integer(nextRequestID)
        nextRequestID += 1

        let outgoingRequest = CodexAppServerOutgoingRequest(
            method: method,
            id: requestID,
            params: parameters
        )
        let encodedRequest = try jsonEncoder.encode(outgoingRequest)
        let timeoutNanoseconds = requestTimeoutNanoseconds

        let responseValue: CodexJSONValue = try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.requestDidTimeOut(requestID: requestID, method: method)
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try transport.send(encodedRequest)
            } catch {
                pendingRequests.removeValue(forKey: requestID)?.timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }

        let responseData = try jsonEncoder.encode(responseValue)
        return try jsonDecoder.decode(Response.self, from: responseData)
    }

    private func sendNotification<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) throws {
        guard connectionState != .disconnected else {
            throw CodexAppServerError.notConnected
        }

        let outgoingNotification = CodexAppServerOutgoingNotification(
            method: method,
            params: parameters
        )
        try transport.send(jsonEncoder.encode(outgoingNotification))
    }

    private func receive(_ messageData: Data) {
        guard let incomingMessage = try? jsonDecoder.decode(
            CodexAppServerIncomingMessage.self,
            from: messageData
        ) else {
            handleFatalProtocolError(.malformedMessage)
            return
        }

        if let method = incomingMessage.method {
            if let requestID = incomingMessage.id {
                serverRequestContinuation.yield(
                    CodexAppServerRequest(
                        id: requestID,
                        method: method,
                        params: incomingMessage.params
                    )
                )
            } else {
                notificationContinuation.yield(
                    CodexAppServerNotification(
                        method: method,
                        params: incomingMessage.params
                    )
                )
            }
            return
        }

        guard let requestID = incomingMessage.id,
              let pendingRequest = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pendingRequest.timeoutTask.cancel()

        if let protocolError = incomingMessage.error {
            pendingRequest.continuation.resume(
                throwing: CodexAppServerError.protocolFailure(
                    code: protocolError.code,
                    message: protocolError.message
                )
            )
        } else if incomingMessage.hasResult, let result = incomingMessage.result {
            pendingRequest.continuation.resume(returning: result)
        } else {
            pendingRequest.continuation.resume(
                throwing: CodexAppServerError.missingResponsePayload
            )
        }
    }

    private func startMonitoringTransportEventsIfNeeded() {
        guard transportEventMonitoringTask == nil else { return }
        transportEventMonitoringTask = Task { [weak self, transportEvents] in
            for await transportEvent in transportEvents {
                guard !Task.isCancelled else { return }
                await self?.reduceTransportEvent(transportEvent)
            }
        }
    }

    private func reduceTransportEvent(_ transportEvent: TransportEvent) {
        guard transportEvent.generation == activeTransportGeneration else { return }
        switch transportEvent {
        case .message(_, let messageData):
            receive(messageData)
        case .termination(_, let terminationError):
            transportDidTerminate(with: terminationError)
        }
    }

    private func requestDidTimeOut(
        requestID: CodexAppServerRequestID,
        method: String
    ) {
        guard pendingRequests[requestID] != nil else { return }
        handleFatalProtocolError(.requestTimedOut(method: method))
    }

    private func transportDidTerminate(with terminationError: CodexAppServerError) {
        activeTransportGeneration = nil
        failPendingRequests(with: terminationError)
        connectionState = .disconnected
    }

    private func handleFatalProtocolError(_ protocolError: CodexAppServerError) {
        activeTransportGeneration = nil
        failPendingRequests(with: protocolError)
        transport.stop()
        connectionState = .disconnected
    }

    private func failPendingRequests(with error: Error) {
        let requestsToFail = Array(pendingRequests.values)
        pendingRequests.removeAll()

        for pendingRequest in requestsToFail {
            pendingRequest.timeoutTask.cancel()
            pendingRequest.continuation.resume(throwing: error)
        }
    }
}
