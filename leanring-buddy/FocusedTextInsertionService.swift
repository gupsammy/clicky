//
//  FocusedTextInsertionService.swift
//  leanring-buddy
//
//  Captures and validates the user's focused control for literal dictation.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
struct DictationFocusContext {
    let applicationProcessIdentifier: pid_t
    let applicationBundleIdentifier: String?
    let focusedElement: AXUIElement
}

enum FocusedTextInsertionMethod: String {
    case selectedText
    case valueReplacement
    case unicodeKeyboardEvents
}

struct FocusedTextInsertionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class FocusedTextInsertionService {
    func captureFocusContext() throws -> DictationFocusContext {
        guard AXIsProcessTrusted() else {
            throw FocusedTextInsertionError(
                message: "Accessibility permission is required for fast dictation."
            )
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw FocusedTextInsertionError(
                message: "Focus a text field in another app before starting fast dictation."
            )
        }

        let applicationElement = AXUIElementCreateApplication(
            frontmostApplication.processIdentifier
        )
        var focusedElementValue: AnyObject?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard focusedElementResult == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            throw FocusedTextInsertionError(
                message: "Clicky could not capture the focused text field."
            )
        }

        let focusedElement = focusedElementValue as! AXUIElement
        guard !isSecureTextEntry(focusedElement) else {
            throw FocusedTextInsertionError(
                message: "Fast dictation is unavailable in secure text fields."
            )
        }
        guard isEditableTextEntry(focusedElement) else {
            throw FocusedTextInsertionError(
                message: "Focus an editable text field before starting fast dictation."
            )
        }

        return DictationFocusContext(
            applicationProcessIdentifier: frontmostApplication.processIdentifier,
            applicationBundleIdentifier: frontmostApplication.bundleIdentifier,
            focusedElement: focusedElement
        )
    }

    private func isSecureTextEntry(_ focusedElement: AXUIElement) -> Bool {
        var subroleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
              let subrole = subroleValue as? String else {
            return false
        }

        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private func isEditableTextEntry(_ focusedElement: AXUIElement) -> Bool {
        var enabledValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success,
           let isEnabled = enabledValue as? Bool,
           !isEnabled {
            return false
        }

        if isAttributeSettable(
            kAXSelectedTextAttribute as CFString,
            on: focusedElement
        ) {
            return true
        }

        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
              let role = roleValue as? String else {
            return false
        }

        if [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String
        ].contains(role) {
            return true
        }

        return role == (kAXComboBoxRole as String)
            && isAttributeSettable(
                kAXValueAttribute as CFString,
                on: focusedElement
            )
    }

    private func isAttributeSettable(
        _ attribute: CFString,
        on focusedElement: AXUIElement
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            focusedElement,
            attribute,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    func insert(
        transcriptText: String,
        into focusContext: DictationFocusContext
    ) async throws -> FocusedTextInsertionMethod {
        let trimmedTranscriptText = transcriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscriptText.isEmpty else {
            throw FocusedTextInsertionError(
                message: "Fast dictation did not produce any text."
            )
        }

        try validateFocusContext(focusContext)
        let insertionPlan = try makeInsertionPlan(
            replacementText: trimmedTranscriptText,
            on: focusContext.focusedElement
        )
        let boundaryAdjustedTranscriptText = insertionPlan?.replacementText
            ?? trimmedTranscriptText

        if setSelectedText(
            boundaryAdjustedTranscriptText,
            on: focusContext.focusedElement
        ) {
            return .selectedText
        }

        if let insertionPlan,
           applyInsertionPlan(insertionPlan, on: focusContext.focusedElement) {
            return .valueReplacement
        }

        try validateFocusContext(focusContext)
        guard let insertionPlan else {
            throw FocusedTextInsertionError(
                message: "This text field does not expose enough state for safe dictation insertion."
            )
        }
        guard postUnicodeKeyboardEvents(boundaryAdjustedTranscriptText) else {
            throw FocusedTextInsertionError(
                message: "Clicky could not send the dictated text to the focused field."
            )
        }

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(25))
            try validateFocusContext(focusContext)
            if let currentTextState = textState(on: focusContext.focusedElement),
               currentTextState.value == insertionPlan.updatedValue {
                return .unicodeKeyboardEvents
            }
        }

        throw FocusedTextInsertionError(
            message: "Clicky could not confirm that the focused field accepted the dictated text."
        )
    }

    private func validateFocusContext(_ focusContext: DictationFocusContext) throws {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier == focusContext.applicationProcessIdentifier,
              frontmostApplication.bundleIdentifier == focusContext.applicationBundleIdentifier else {
            throw FocusedTextInsertionError(
                message: "The focused app changed while you were dictating, so Clicky did not insert the text."
            )
        }

        let applicationElement = AXUIElementCreateApplication(
            focusContext.applicationProcessIdentifier
        )
        var currentFocusedElementValue: AnyObject?
        let currentFocusedElementResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &currentFocusedElementValue
        )

        guard currentFocusedElementResult == .success,
              let currentFocusedElementValue,
              CFEqual(
                currentFocusedElementValue,
                focusContext.focusedElement
              ) else {
            throw FocusedTextInsertionError(
                message: "The focused field changed while you were dictating, so Clicky did not insert the text."
            )
        }

        guard isEditableTextEntry(focusContext.focusedElement) else {
            throw FocusedTextInsertionError(
                message: "The focused field is no longer editable, so Clicky did not insert the text."
            )
        }
    }

    private func setSelectedText(
        _ transcriptText: String,
        on focusedElement: AXUIElement
    ) -> Bool {
        var isSelectedTextSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSelectedTextSettable
        )

        guard settableResult == .success, isSelectedTextSettable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            transcriptText as CFString
        ) == .success
    }

    private func makeInsertionPlan(
        replacementText: String,
        on focusedElement: AXUIElement
    ) throws -> FocusedTextInsertionPlan? {
        guard let textState = textState(on: focusedElement) else { return nil }

        return try FocusedTextInsertionPlan(
            currentValue: textState.value,
            selectedUTF16Range: textState.selectedRange,
            replacementText: replacementText
        )
    }

    private func textState(on focusedElement: AXUIElement) -> FocusedTextState? {
        var currentValueObject: AnyObject?
        var selectedRangeObject: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValueObject
        ) == .success,
              AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                &selectedRangeObject
              ) == .success,
              let currentValue = currentValueObject as? String,
              let selectedRangeObject,
              CFGetTypeID(selectedRangeObject) == AXValueGetTypeID() else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(
            selectedRangeObject as! AXValue,
            .cfRange,
            &selectedRange
        ) else {
            return nil
        }

        return FocusedTextState(
            value: currentValue,
            selectedRange: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            )
        )
    }

    private func applyInsertionPlan(
        _ insertionPlan: FocusedTextInsertionPlan,
        on focusedElement: AXUIElement
    ) -> Bool {
        guard isAttributeSettable(
            kAXValueAttribute as CFString,
            on: focusedElement
        ) else {
            return false
        }

        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            insertionPlan.updatedValue as CFString
        ) == .success else {
            return false
        }

        var updatedSelectionRange = CFRange(
            location: insertionPlan.updatedSelectionRange.location,
            length: insertionPlan.updatedSelectionRange.length
        )
        if let updatedSelectionValue = AXValueCreate(
            .cfRange,
            &updatedSelectionRange
        ) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                updatedSelectionValue
            )
        }

        return true
    }

    private func postUnicodeKeyboardEvents(_ transcriptText: String) -> Bool {
        // The OS truncates keyboardSetUnicodeString payloads beyond ~20 UTF-16
        // code units per event, so the transcript is posted as one keyDown/
        // keyUp pair per bounded chunk instead of a single oversized event.
        let keystrokeChunks = FocusedTextUnicodeKeystrokeChunker
            .utf16KeystrokeChunks(for: transcriptText)

        for keystrokeChunk in keystrokeChunks {
            guard let keyDownEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            ),
                  let keyUpEvent = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: false
                  ) else {
                return false
            }

            keystrokeChunk.withUnsafeBufferPointer { chunkBuffer in
                keyDownEvent.keyboardSetUnicodeString(
                    stringLength: chunkBuffer.count,
                    unicodeString: chunkBuffer.baseAddress
                )
            }
            keyDownEvent.post(tap: .cghidEventTap)
            keyUpEvent.post(tap: .cghidEventTap)
        }
        return true
    }
}

private struct FocusedTextState: Equatable {
    let value: String
    let selectedRange: NSRange
}
