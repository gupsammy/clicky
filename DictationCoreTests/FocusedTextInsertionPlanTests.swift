import Foundation
import Testing
@testable import ClickyDictationCore

@Test func insertsAtTheCurrentUTF16Caret() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "Hello world",
        selectedUTF16Range: NSRange(location: 5, length: 0),
        replacementText: ", brave"
    )

    #expect(plan.updatedValue == "Hello, brave world")
    #expect(plan.updatedSelectionRange == NSRange(location: 12, length: 0))
}

@Test func replacesTheSelectedUTF16Range() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "ship the old draft",
        selectedUTF16Range: NSRange(location: 9, length: 9),
        replacementText: "new version"
    )

    #expect(plan.updatedValue == "ship the new version")
    #expect(plan.updatedSelectionRange == NSRange(location: 20, length: 0))
}

@Test func addsWordBoundarySpacingAtAnOrdinaryCaret() throws {
    let plan = try FocusedTextInsertionPlan(
        currentValue: "hellothere",
        selectedUTF16Range: NSRange(location: 5, length: 0),
        replacementText: "world"
    )

    #expect(plan.replacementText == " world ")
    #expect(plan.updatedValue == "hello world there")
    #expect(plan.updatedSelectionRange == NSRange(location: 12, length: 0))
}

@Test func preservesUnicodeOutsideTheSelection() throws {
    let currentValue = "🚀 old"
    let oldWordRange = (currentValue as NSString).range(of: "old")
    let plan = try FocusedTextInsertionPlan(
        currentValue: currentValue,
        selectedUTF16Range: oldWordRange,
        replacementText: "ready"
    )

    #expect(plan.updatedValue == "🚀 ready")
}

@Test func rejectsAStaleSelectionRange() {
    #expect(throws: FocusedTextInsertionPlanError.self) {
        try FocusedTextInsertionPlan(
            currentValue: "short",
            selectedUTF16Range: NSRange(location: 20, length: 0),
            replacementText: "unsafe"
        )
    }
}

@Test func keystrokeChunkerKeepsShortTextInASingleChunk() {
    let chunks = FocusedTextUnicodeKeystrokeChunker.utf16KeystrokeChunks(for: "Hello world")
    #expect(chunks.count == 1)
    #expect(chunks[0] == Array("Hello world".utf16))
}

@Test func keystrokeChunkerBoundsEveryChunkAndPreservesAllCodeUnits() {
    let longTranscript = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 5)
    let chunks = FocusedTextUnicodeKeystrokeChunker.utf16KeystrokeChunks(for: longTranscript)

    #expect(chunks.count > 1)
    for chunk in chunks {
        #expect(chunk.count <= FocusedTextUnicodeKeystrokeChunker.maximumCodeUnitsPerKeystrokeEvent)
        #expect(!chunk.isEmpty)
    }
    #expect(chunks.flatMap { $0 } == Array(longTranscript.utf16))
}

@Test func keystrokeChunkerNeverSplitsASurrogatePairAcrossChunks() {
    // 19 ASCII code units followed by an emoji (2 UTF-16 code units): the
    // emoji does not fit in the first 20-unit chunk and must move to the
    // second chunk whole rather than being split at the buffer boundary.
    let transcript = String(repeating: "a", count: 19) + "😀" + "tail"
    let chunks = FocusedTextUnicodeKeystrokeChunker.utf16KeystrokeChunks(for: transcript)

    #expect(chunks[0].count == 19)
    #expect(Array(chunks[1].prefix(2)) == Array("😀".utf16))
    #expect(chunks.flatMap { $0 } == Array(transcript.utf16))
}
