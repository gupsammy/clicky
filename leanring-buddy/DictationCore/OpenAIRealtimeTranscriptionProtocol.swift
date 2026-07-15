import Foundation

public enum OpenAIRealtimeTranscriptionDelay: String, Sendable {
    case minimal
    case low
    case medium
    case high
    case extraHigh = "xhigh"
}

public struct OpenAIRealtimeTranscriptionConfiguration: Sendable {
    public let modelName: String
    public let languageCode: String
    public let delay: OpenAIRealtimeTranscriptionDelay

    public init(
        modelName: String = "gpt-realtime-whisper",
        languageCode: String = "en",
        delay: OpenAIRealtimeTranscriptionDelay = .low
    ) {
        self.modelName = modelName
        self.languageCode = languageCode
        self.delay = delay
    }

    public func makeSessionUpdateEventData() throws -> Data {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": [
                            "model": modelName,
                            "language": languageCode,
                            "delay": delay.rawValue
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: event)
    }
}

public enum OpenAIRealtimeTranscriptionClientEventEncoder {
    public static func makeAudioAppendEventData(pcm16AudioData: Data) throws -> Data {
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16AudioData.base64EncodedString()
        ]

        return try JSONSerialization.data(withJSONObject: event)
    }

    public static func makeAudioCommitEventData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.commit"
        ])
    }
}

public enum OpenAIRealtimeTranscriptionServerEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case audioBufferCommitted(itemIdentifier: String)
    case transcriptDelta(itemIdentifier: String, deltaText: String)
    case transcriptCompleted(itemIdentifier: String, transcriptText: String)
    case transcriptionFailed(itemIdentifier: String?, message: String)
    case serverError(message: String)
    case ignored(type: String)

    public static func parse(data: Data) throws -> OpenAIRealtimeTranscriptionServerEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = object["type"] as? String else {
            throw OpenAIRealtimeTranscriptionProtocolError(
                message: "OpenAI Realtime returned an event without a type."
            )
        }

        switch eventType {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.committed":
            return .audioBufferCommitted(
                itemIdentifier: try requiredString(named: "item_id", in: object)
            )
        case "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(
                itemIdentifier: try requiredString(named: "item_id", in: object),
                deltaText: try requiredString(named: "delta", in: object)
            )
        case "conversation.item.input_audio_transcription.completed":
            return .transcriptCompleted(
                itemIdentifier: try requiredString(named: "item_id", in: object),
                transcriptText: try requiredString(named: "transcript", in: object)
            )
        case "conversation.item.input_audio_transcription.failed":
            return .transcriptionFailed(
                itemIdentifier: object["item_id"] as? String,
                message: nestedErrorMessage(in: object)
                    ?? "OpenAI Realtime could not transcribe the audio."
            )
        case "error":
            return .serverError(
                message: nestedErrorMessage(in: object)
                    ?? "OpenAI Realtime returned an unknown error."
            )
        default:
            return .ignored(type: eventType)
        }
    }

    private static func requiredString(
        named key: String,
        in object: [String: Any]
    ) throws -> String {
        guard let value = object[key] as? String else {
            throw OpenAIRealtimeTranscriptionProtocolError(
                message: "OpenAI Realtime event is missing \(key)."
            )
        }

        return value
    }

    private static func nestedErrorMessage(in object: [String: Any]) -> String? {
        guard let errorObject = object["error"] as? [String: Any] else { return nil }
        return errorObject["message"] as? String
    }
}

public struct OpenAIRealtimeTranscriptAccumulator: Sendable {
    private var itemIdentifiersInArrivalOrder: [String] = []
    private var transcriptTextByItemIdentifier: [String: String] = [:]

    public init() {}

    public mutating func apply(
        _ event: OpenAIRealtimeTranscriptionServerEvent
    ) -> String? {
        switch event {
        case .transcriptDelta(let itemIdentifier, let deltaText):
            registerItemIdentifierIfNeeded(itemIdentifier)
            transcriptTextByItemIdentifier[itemIdentifier, default: ""] += deltaText
            return fullTranscriptText
        case .transcriptCompleted(let itemIdentifier, let transcriptText):
            registerItemIdentifierIfNeeded(itemIdentifier)
            transcriptTextByItemIdentifier[itemIdentifier] = transcriptText
            return fullTranscriptText
        default:
            return nil
        }
    }

    public var fullTranscriptText: String {
        itemIdentifiersInArrivalOrder
            .compactMap { transcriptTextByItemIdentifier[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private mutating func registerItemIdentifierIfNeeded(_ itemIdentifier: String) {
        guard !itemIdentifiersInArrivalOrder.contains(itemIdentifier) else { return }
        itemIdentifiersInArrivalOrder.append(itemIdentifier)
    }
}

public struct OpenAIRealtimeTranscriptionProtocolError: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
