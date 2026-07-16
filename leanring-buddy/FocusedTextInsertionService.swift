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

struct ScreenAwareFocusedTextContext {
    let applicationName: String?
    let windowTitle: String?
    let selectedText: String?
    let textBeforeSelection: String?
    let textAfterSelection: String?
    let focusedElementFrameInCoreGraphicsCoordinates: CGRect?
    fileprivate let sourceValue: String
    fileprivate let sourceSelectedRange: NSRange
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
    private let maximumScreenAwareContextCharacterCount = 8_000

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

    func screenAwareContext(
        for focusContext: DictationFocusContext
    ) throws -> ScreenAwareFocusedTextContext {
        try validateFocusContext(focusContext)
        guard let currentTextState = textState(on: focusContext.focusedElement) else {
            throw FocusedTextInsertionError(
                message: "This text field does not expose enough context for screen-aware dictation."
            )
        }

        let currentValue = currentTextState.value as NSString
        let selectedRange = currentTextState.selectedRange
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= currentValue.length,
              selectedRange.length <= currentValue.length - selectedRange.location else {
            throw FocusedTextInsertionError(
                message: "The focused text selection is outside the current value."
            )
        }

        let selectionEndLocation = selectedRange.location + selectedRange.length
        let selectedText = boundedSubstringKeepingEnd(
            of: currentValue,
            in: selectedRange
        )
        let textBeforeSelection = boundedSubstringKeepingEnd(
            of: currentValue,
            in: NSRange(location: 0, length: selectedRange.location)
        )
        let textAfterSelection = boundedSubstringKeepingStart(
            of: currentValue,
            in: NSRange(
                location: selectionEndLocation,
                length: currentValue.length - selectionEndLocation
            )
        )

        return ScreenAwareFocusedTextContext(
            applicationName: NSRunningApplication(
                processIdentifier: focusContext.applicationProcessIdentifier
            )?.localizedName,
            windowTitle: focusedWindowTitle(for: focusContext.focusedElement),
            selectedText: selectedText,
            textBeforeSelection: textBeforeSelection,
            textAfterSelection: textAfterSelection,
            focusedElementFrameInCoreGraphicsCoordinates: focusedElementFrame(
                for: focusContext.focusedElement
            ),
            sourceValue: currentTextState.value,
            sourceSelectedRange: currentTextState.selectedRange
        )
    }

    func insertScreenAwareComposition(
        compositionText: String,
        into focusContext: DictationFocusContext,
        matching screenAwareFocusedTextContext: ScreenAwareFocusedTextContext
    ) async throws -> FocusedTextInsertionMethod {
        try validateScreenAwareFocusedTextContext(
            screenAwareFocusedTextContext,
            for: focusContext
        )

        return try await insert(
            transcriptText: compositionText,
            into: focusContext
        )
    }

    func validateScreenAwareFocusedTextContext(
        _ screenAwareFocusedTextContext: ScreenAwareFocusedTextContext,
        for focusContext: DictationFocusContext
    ) throws {
        try validateFocusContext(focusContext)
        guard let currentTextState = textState(on: focusContext.focusedElement),
              currentTextState.value == screenAwareFocusedTextContext.sourceValue,
              currentTextState.selectedRange == screenAwareFocusedTextContext.sourceSelectedRange else {
            throw FocusedTextInsertionError(
                message: "The focused text changed while Clicky was composing, so Clicky did not insert the result."
            )
        }
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

    private func focusedWindowTitle(for focusedElement: AXUIElement) -> String? {
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowValue as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else {
            return nil
        }
        return titleValue as? String
    }

    private func focusedElementFrame(for focusedElement: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    // The focused element's AX value can be an entire multi-megabyte document,
    // and screenAwareContext(for:) runs on the push-to-talk key-down path.
    // Clamping the range to the UTF-16 budget BEFORE calling substring(with:)
    // keeps each copy bounded instead of materializing the whole document and
    // then truncating it.
    private func boundedSubstringKeepingEnd(
        of value: NSString,
        in range: NSRange
    ) -> String? {
        guard range.length > 0 else { return nil }

        var clampedRange = range
        if range.length > maximumScreenAwareContextCharacterCount {
            let budgetCutLocation = range.location + range.length
                - maximumScreenAwareContextCharacterCount
            // Snap the cut forward to the next composed character boundary so
            // a surrogate pair or emoji cluster is never split at the edge.
            let composedSequenceAtCut = value.rangeOfComposedCharacterSequence(
                at: budgetCutLocation
            )
            let snappedCutLocation = composedSequenceAtCut.location == budgetCutLocation
                ? budgetCutLocation
                : min(
                    composedSequenceAtCut.location + composedSequenceAtCut.length,
                    range.location + range.length
                )
            clampedRange = NSRange(
                location: snappedCutLocation,
                length: range.location + range.length - snappedCutLocation
            )
        }

        let boundedValue = value.substring(with: clampedRange)
        return boundedValue.isEmpty ? nil : boundedValue
    }

    private func boundedSubstringKeepingStart(
        of value: NSString,
        in range: NSRange
    ) -> String? {
        guard range.length > 0 else { return nil }

        var clampedRange = range
        if range.length > maximumScreenAwareContextCharacterCount {
            let budgetCutLocation = range.location
                + maximumScreenAwareContextCharacterCount
            // Snap the cut back to the start of the composed character it
            // lands inside so a surrogate pair or emoji cluster is never split.
            let composedSequenceAtCut = value.rangeOfComposedCharacterSequence(
                at: budgetCutLocation
            )
            let snappedCutLocation = max(
                composedSequenceAtCut.location,
                range.location
            )
            clampedRange = NSRange(
                location: range.location,
                length: snappedCutLocation - range.location
            )
        }

        let boundedValue = value.substring(with: clampedRange)
        return boundedValue.isEmpty ? nil : boundedValue
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
