import Foundation
import Testing
@testable import ClickyDictationCore

@Test func requestBoundsPrivateTextContextAndEncodesTheScreenshot() throws {
    let request = try ScreenAwareCompositionRequest(
        spokenInstruction: "  reply politely  ",
        applicationName: "Mail",
        windowTitle: "Project update",
        selectedText: nil,
        textBeforeSelection: String(repeating: "a", count: 9_000),
        textAfterSelection: "Thanks",
        screenshotJPEGData: Data([0xFF, 0xD8, 0xFF])
    )

    #expect(request.spokenInstruction == "reply politely")
    #expect(request.textBeforeSelection?.count == 8_000)
    #expect(request.screenshotJPEGBase64 == "/9j/")
}

@Test func requestRejectsMissingInstructionOrScreenshot() {
    #expect(throws: ScreenAwareCompositionProtocolError.self) {
        try ScreenAwareCompositionRequest(
            spokenInstruction: " ",
            applicationName: nil,
            windowTitle: nil,
            selectedText: nil,
            textBeforeSelection: nil,
            textAfterSelection: nil,
            screenshotJPEGData: Data([1])
        )
    }

    #expect(throws: ScreenAwareCompositionProtocolError.self) {
        try ScreenAwareCompositionRequest(
            spokenInstruction: "write a reply",
            applicationName: nil,
            windowTitle: nil,
            selectedText: nil,
            textBeforeSelection: nil,
            textAfterSelection: nil,
            screenshotJPEGData: Data(repeating: 1, count: 4_500_001)
        )
    }

    #expect(throws: ScreenAwareCompositionProtocolError.self) {
        try ScreenAwareCompositionRequest(
            spokenInstruction: "write a reply",
            applicationName: nil,
            windowTitle: nil,
            selectedText: nil,
            textBeforeSelection: nil,
            textAfterSelection: nil,
            screenshotJPEGData: Data()
        )
    }
}

@Test func requestBuildsCodexPromptWithoutEmbeddingScreenshotData() throws {
    let request = try ScreenAwareCompositionRequest(
        spokenInstruction: "reply politely",
        applicationName: "Mail",
        windowTitle: "Project update",
        selectedText: "Can you ship today?",
        textBeforeSelection: "Sam wrote:",
        textAfterSelection: "Thanks",
        screenshotJPEGData: Data([0xFF, 0xD8, 0xFF])
    )

    #expect(request.codexTextPrompt.contains("Spoken instruction: reply politely"))
    #expect(request.codexTextPrompt.contains("Application:\n<field-context>\nMail"))
    #expect(request.codexTextPrompt.contains("Selected text:\n<field-context>\nCan you ship today?"))
    #expect(request.codexTextPrompt.contains("Return only the exact text to insert."))
    #expect(!request.codexTextPrompt.contains(request.screenshotJPEGBase64))
}

@Test func responseRejectsEmptyCompositions() throws {
    let response = try ScreenAwareCompositionResponse.decode(
        data: Data(#"{"text":"  Ready to ship.  "}"#.utf8)
    )
    #expect(response.text == "Ready to ship.")

    #expect(throws: ScreenAwareCompositionProtocolError.self) {
        try ScreenAwareCompositionResponse.decode(
            data: Data(#"{"text":"   "}"#.utf8)
        )
    }


    #expect(throws: ScreenAwareCompositionProtocolError.self) {
        try ScreenAwareCompositionResponse(
            text: String(repeating: "a", count: 20_001)
        )
    }
}

@Test func displaySelectionUsesFocusedElementCenter() {
    let selectedDisplayIndex = ScreenAwareDisplaySelector.displayIndex(
        containing: CGRect(x: 1_100, y: 100, width: 200, height: 50),
        displayFrames: [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
        ]
    )

    #expect(selectedDisplayIndex == 1)
}

@Test func displaySelectionFailsClosedWhenFocusedElementIsOutsideEveryDisplay() {
    let selectedDisplayIndex = ScreenAwareDisplaySelector.displayIndex(
        containing: CGRect(x: 3_000, y: 100, width: 200, height: 50),
        displayFrames: [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
        ]
    )

    #expect(selectedDisplayIndex == nil)
}
