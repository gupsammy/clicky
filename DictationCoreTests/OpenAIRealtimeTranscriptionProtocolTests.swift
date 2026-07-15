import Foundation
import Testing
@testable import ClickyDictationCore

@Test func sessionUpdateUsesRealtimeWhisperAndManualCommit() throws {
    let configuration = OpenAIRealtimeTranscriptionConfiguration(delay: .minimal)
    let eventData = try configuration.makeSessionUpdateEventData()
    let event = try #require(
        JSONSerialization.jsonObject(with: eventData) as? [String: Any]
    )
    let session = try #require(event["session"] as? [String: Any])
    let audio = try #require(session["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let format = try #require(input["format"] as? [String: Any])
    let transcription = try #require(input["transcription"] as? [String: Any])

    #expect(event["type"] as? String == "session.update")
    #expect(session["type"] as? String == "transcription")
    #expect(format["type"] as? String == "audio/pcm")
    #expect(format["rate"] as? Int == 24_000)
    #expect(transcription["model"] as? String == "gpt-realtime-whisper")
    #expect(transcription["delay"] as? String == "minimal")
    #expect(input["turn_detection"] is NSNull)
}

@Test func audioAppendEventBase64EncodesPCM16Bytes() throws {
    let audioData = Data([0x00, 0x01, 0xFE, 0xFF])
    let eventData = try OpenAIRealtimeTranscriptionClientEventEncoder
        .makeAudioAppendEventData(pcm16AudioData: audioData)
    let event = try #require(
        JSONSerialization.jsonObject(with: eventData) as? [String: Any]
    )

    #expect(event["type"] as? String == "input_audio_buffer.append")
    #expect(event["audio"] as? String == audioData.base64EncodedString())
}

@Test func parserRecognizesTranscriptAndErrorEvents() throws {
    let deltaEvent = try OpenAIRealtimeTranscriptionServerEvent.parse(data: Data(
        #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"Hello"}"#.utf8
    ))
    let completedEvent = try OpenAIRealtimeTranscriptionServerEvent.parse(data: Data(
        #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"Hello world"}"#.utf8
    ))
    let failedEvent = try OpenAIRealtimeTranscriptionServerEvent.parse(data: Data(
        #"{"type":"conversation.item.input_audio_transcription.failed","item_id":"item-1","error":{"message":"bad audio"}}"#.utf8
    ))

    #expect(deltaEvent == .transcriptDelta(itemIdentifier: "item-1", deltaText: "Hello"))
    #expect(completedEvent == .transcriptCompleted(itemIdentifier: "item-1", transcriptText: "Hello world"))
    #expect(failedEvent == .transcriptionFailed(itemIdentifier: "item-1", message: "bad audio"))
}

@Test func accumulatorReconcilesCompletedTextAndPreservesItemOrder() {
    var accumulator = OpenAIRealtimeTranscriptAccumulator()

    #expect(accumulator.apply(.transcriptDelta(
        itemIdentifier: "item-1",
        deltaText: "Hello wor"
    )) == "Hello wor")
    #expect(accumulator.apply(.transcriptDelta(
        itemIdentifier: "item-2",
        deltaText: "Second"
    )) == "Hello wor Second")
    #expect(accumulator.apply(.transcriptCompleted(
        itemIdentifier: "item-1",
        transcriptText: "Hello world."
    )) == "Hello world. Second")
}
