//
//  OpenAIRealtimeTranscriptionProvider.swift
//  leanring-buddy
//
//  Low-latency streaming transcription backed by OpenAI Realtime.
//

import AVFoundation
import Foundation

struct OpenAIRealtimeTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class OpenAIRealtimeTranscriptionProvider: BuddyTranscriptionProvider {
    private struct EphemeralTokenResponse: Decodable {
        let token: String
        let expiresAt: Int?
    }

    let displayName = "OpenAI Realtime"
    let requiresSpeechRecognitionPermission = false

    private let sharedWebSocketURLSession = URLSession(configuration: .default)
    private let transcriptionConfiguration: OpenAIRealtimeTranscriptionConfiguration

    init() {
        let configuredDelay = AppBundleConfiguration
            .stringValue(forKey: "OpenAIRealtimeTranscriptionDelay")
            .flatMap(OpenAIRealtimeTranscriptionDelay.init(rawValue:))
            ?? .low

        transcriptionConfiguration = OpenAIRealtimeTranscriptionConfiguration(
            modelName: AppBundleConfiguration
                .stringValue(forKey: "OpenAIRealtimeTranscriptionModel")
                ?? "gpt-realtime-whisper",
            languageCode: AppBundleConfiguration
                .stringValue(forKey: "OpenAIRealtimeTranscriptionLanguage")
                ?? "en",
            delay: configuredDelay
        )
    }

    var isConfigured: Bool {
        ephemeralTokenProxyURL != nil
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "OpenAI Realtime transcription is not configured. Set ClickyAPIProxyBaseURL in Info.plist."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let ephemeralTokenProxyURL else {
            throw OpenAIRealtimeTranscriptionProviderError(
                message: unavailableExplanation
                    ?? "OpenAI Realtime transcription is not configured."
            )
        }

        // GA gpt-realtime-whisper sessions do not support prompt steering.
        // Keep collecting keyterms at the manager seam for the later
        // screen-aware cleanup layer instead of sending an unsupported field.
        _ = keyterms

        let ephemeralToken = try await fetchEphemeralToken(
            from: ephemeralTokenProxyURL
        )
        let session = OpenAIRealtimeTranscriptionSession(
            ephemeralToken: ephemeralToken,
            urlSession: sharedWebSocketURLSession,
            transcriptionConfiguration: transcriptionConfiguration,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    private var ephemeralTokenProxyURL: URL? {
        if let configuredTokenProxyURL = AppBundleConfiguration
            .stringValue(forKey: "OpenAIRealtimeTokenProxyURL"),
           !configuredTokenProxyURL.contains("your-worker-name"),
           let tokenProxyURL = URL(string: configuredTokenProxyURL) {
            return tokenProxyURL
        }

        guard let configuredWorkerBaseURL = AppBundleConfiguration
            .stringValue(forKey: "ClickyAPIProxyBaseURL"),
              !configuredWorkerBaseURL.contains("your-worker-name"),
              let workerBaseURL = URL(string: configuredWorkerBaseURL) else {
            return nil
        }

        return workerBaseURL.appendingPathComponent("openai-realtime-token")
    }

    private func fetchEphemeralToken(from tokenProxyURL: URL) async throws -> String {
        var request = URLRequest(url: tokenProxyURL)
        request.httpMethod = "POST"

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let HTTPResponse = response as? HTTPURLResponse,
              (200...299).contains(HTTPResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenAIRealtimeTranscriptionProviderError(
                message: "OpenAI Realtime token request failed with HTTP \(statusCode)."
            )
        }

        let tokenResponse = try JSONDecoder().decode(
            EphemeralTokenResponse.self,
            from: responseData
        )
        let trimmedToken = tokenResponse.token
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedToken.isEmpty else {
            throw OpenAIRealtimeTranscriptionProviderError(
                message: "OpenAI Realtime token response was empty."
            )
        }

        return trimmedToken
    }
}

private final class OpenAIRealtimeTranscriptionSession: BuddyStreamingTranscriptionSession, @unchecked Sendable {
    private static let targetSampleRate = 24_000.0
    private static let webSocketURL = URL(
        string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-whisper"
    )!

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0

    private let ephemeralToken: String
    private let urlSession: URLSession
    private let transcriptionConfiguration: OpenAIRealtimeTranscriptionConfiguration
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(
        label: "com.learningbuddy.openai.realtime.transcription.state"
    )
    private let sendQueue = DispatchQueue(
        label: "com.learningbuddy.openai.realtime.transcription.send"
    )
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: targetSampleRate
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var transcriptAccumulator = OpenAIRealtimeTranscriptAccumulator()
    private var hasSentAudio = false
    private var isAwaitingFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var hasFailed = false
    private var isCancelled = false

    init(
        ephemeralToken: String,
        urlSession: URLSession,
        transcriptionConfiguration: OpenAIRealtimeTranscriptionConfiguration,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.ephemeralToken = ephemeralToken
        self.urlSession = urlSession
        self.transcriptionConfiguration = transcriptionConfiguration
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        var webSocketRequest = URLRequest(url: Self.webSocketURL)
        webSocketRequest.setValue(
            "Bearer \(ephemeralToken)",
            forHTTPHeaderField: "Authorization"
        )

        let webSocketTask = urlSession.webSocketTask(with: webSocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation

                do {
                    let sessionUpdateEventData = try self.transcriptionConfiguration
                        .makeSessionUpdateEventData()
                    self.sendEventData(sessionUpdateEventData)
                } catch {
                    self.failSession(with: error)
                }
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let PCM16AudioData = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !PCM16AudioData.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.isCancelled, !self.isAwaitingFinalTranscript else { return }
            self.hasSentAudio = true

            do {
                let appendEventData = try OpenAIRealtimeTranscriptionClientEventEncoder
                    .makeAudioAppendEventData(pcm16AudioData: PCM16AudioData)
                self.sendEventData(appendEventData)
            } catch {
                self.failSession(with: error)
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.isCancelled,
                  !self.isAwaitingFinalTranscript,
                  !self.hasDeliveredFinalTranscript else {
                return
            }

            self.isAwaitingFinalTranscript = true

            guard self.hasSentAudio else {
                self.deliverFinalTranscriptIfNeeded("")
                return
            }

            do {
                let commitEventData = try OpenAIRealtimeTranscriptionClientEventEncoder
                    .makeAudioCommitEventData()
                self.sendEventData(commitEventData)
            } catch {
                self.failSession(with: error)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            guard !self.isCancelled else { return }
            self.isCancelled = true

            if !self.hasResolvedReadyContinuation {
                self.resolveReadyContinuationIfNeeded(
                    with: .failure(CancellationError())
                )
            }
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let messageData = text.data(using: .utf8) {
                        self.handleIncomingMessageData(messageData)
                    }
                case .data(let messageData):
                    self.handleIncomingMessageData(messageData)
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.stateQueue.async {
                    guard !self.isCancelled else { return }
                    self.failSession(with: error)
                }
            }
        }
    }

    private func handleIncomingMessageData(_ messageData: Data) {
        do {
            let event = try OpenAIRealtimeTranscriptionServerEvent.parse(
                data: messageData
            )
            stateQueue.async {
                self.handleServerEvent(event)
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleServerEvent(_ event: OpenAIRealtimeTranscriptionServerEvent) {
        guard !isCancelled else { return }

        switch event {
        case .sessionUpdated:
            resolveReadyContinuationIfNeeded(with: .success(()))
        case .transcriptDelta:
            publishTranscriptUpdate(for: event)
        case .transcriptCompleted:
            publishTranscriptUpdate(for: event)

            if isAwaitingFinalTranscript {
                deliverFinalTranscriptIfNeeded(
                    transcriptAccumulator.fullTranscriptText
                )
            }
        case .transcriptionFailed(_, let message), .serverError(let message):
            failSession(with: OpenAIRealtimeTranscriptionProviderError(message: message))
        case .sessionCreated, .audioBufferCommitted, .ignored:
            break
        }
    }

    private func publishTranscriptUpdate(
        for event: OpenAIRealtimeTranscriptionServerEvent
    ) {
        guard let transcriptText = transcriptAccumulator.apply(event),
              !transcriptText.isEmpty else {
            return
        }

        onTranscriptUpdate(transcriptText)
    }

    private func sendEventData(_ eventData: Data) {
        guard let eventText = String(data: eventData, encoding: .utf8) else {
            failSession(with: OpenAIRealtimeTranscriptionProviderError(
                message: "OpenAI Realtime event could not be encoded."
            ))
            return
        }

        sendQueue.async { [weak self] in
            guard let self,
                  !self.isCancelled,
                  let webSocketTask = self.webSocketTask else {
                return
            }

            webSocketTask.send(.string(eventText)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        stateQueue.async {
            guard !self.hasFailed, !self.isCancelled else { return }
            self.hasFailed = true
            self.resolveReadyContinuationIfNeeded(with: .failure(error))

            let partialTranscriptText = self.transcriptAccumulator.fullTranscriptText
            if self.isAwaitingFinalTranscript && !partialTranscriptText.isEmpty {
                self.deliverFinalTranscriptIfNeeded(partialTranscriptText)
                return
            }

            self.onError(error)
        }
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(
            transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func resolveReadyContinuationIfNeeded(
        with result: Result<Void, Error>
    ) {
        guard !hasResolvedReadyContinuation else { return }
        hasResolvedReadyContinuation = true

        switch result {
        case .success:
            readyContinuation?.resume()
        case .failure(let error):
            readyContinuation?.resume(throwing: error)
        }

        readyContinuation = nil
    }

    deinit {
        cancel()
    }
}
