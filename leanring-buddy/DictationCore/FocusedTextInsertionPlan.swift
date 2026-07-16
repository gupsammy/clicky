import Foundation

public struct FocusedTextInsertionPlan: Equatable, Sendable {
    public let replacementText: String
    public let updatedValue: String
    public let updatedSelectionRange: NSRange

    public init(
        currentValue: String,
        selectedUTF16Range: NSRange,
        replacementText: String
    ) throws {
        let currentValueNSString = currentValue as NSString
        let currentUTF16Length = currentValueNSString.length

        guard selectedUTF16Range.location != NSNotFound,
              selectedUTF16Range.location <= currentUTF16Length,
              selectedUTF16Range.length <= currentUTF16Length - selectedUTF16Range.location else {
            throw FocusedTextInsertionPlanError(
                message: "The focused text selection is outside the current value."
            )
        }

        let boundaryAdjustedReplacementText = Self.boundaryAdjustedReplacementText(
            currentValue: currentValueNSString,
            selectedUTF16Range: selectedUTF16Range,
            replacementText: replacementText
        )
        let updatedValue = currentValueNSString.mutableCopy() as! NSMutableString
        updatedValue.replaceCharacters(
            in: selectedUTF16Range,
            with: boundaryAdjustedReplacementText
        )

        self.replacementText = boundaryAdjustedReplacementText
        self.updatedValue = updatedValue as String
        self.updatedSelectionRange = NSRange(
            location: selectedUTF16Range.location
                + (boundaryAdjustedReplacementText as NSString).length,
            length: 0
        )
    }

    private static func boundaryAdjustedReplacementText(
        currentValue: NSString,
        selectedUTF16Range: NSRange,
        replacementText: String
    ) -> String {
        guard selectedUTF16Range.length == 0, !replacementText.isEmpty else {
            return replacementText
        }

        var adjustedReplacementText = replacementText
        if selectedUTF16Range.location > 0,
           isAlphanumericUTF16CodeUnit(
               in: currentValue,
               at: selectedUTF16Range.location - 1
           ),
           replacementText.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true {
            adjustedReplacementText.insert(" ", at: adjustedReplacementText.startIndex)
        }

        let selectionEndLocation = selectedUTF16Range.location + selectedUTF16Range.length
        if selectionEndLocation < currentValue.length,
           isAlphanumericUTF16CodeUnit(in: currentValue, at: selectionEndLocation),
           replacementText.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) == true {
            adjustedReplacementText.append(" ")
        }

        return adjustedReplacementText
    }

    private static func isAlphanumericUTF16CodeUnit(
        in value: NSString,
        at location: Int
    ) -> Bool {
        let utf16CodeUnit = value.character(at: location)
        guard let unicodeScalar = UnicodeScalar(utf16CodeUnit) else { return false }
        return CharacterSet.alphanumerics.contains(unicodeScalar)
    }
}

public enum FocusedTextUnicodeKeystrokeChunker {
    // CGEvent's keyboardSetUnicodeString buffer holds at most 20 UTF-16 code
    // units per event; anything longer is silently truncated by the OS, so a
    // long transcript must be posted as multiple keyDown/keyUp pairs.
    public static let maximumCodeUnitsPerKeystrokeEvent = 20

    // Chunks are built from whole unicode scalars so a surrogate pair (e.g.
    // an emoji) can never be split across two keystroke events, which would
    // type invalid UTF-16 into the focused field.
    public static func utf16KeystrokeChunks(for text: String) -> [[UInt16]] {
        var keystrokeChunks: [[UInt16]] = []
        var currentChunk: [UInt16] = []
        currentChunk.reserveCapacity(maximumCodeUnitsPerKeystrokeEvent)

        for unicodeScalar in text.unicodeScalars {
            let scalarCodeUnits = Array(String(unicodeScalar).utf16)
            if !currentChunk.isEmpty,
               currentChunk.count + scalarCodeUnits.count > maximumCodeUnitsPerKeystrokeEvent {
                keystrokeChunks.append(currentChunk)
                currentChunk = []
            }
            currentChunk.append(contentsOf: scalarCodeUnits)
        }

        if !currentChunk.isEmpty {
            keystrokeChunks.append(currentChunk)
        }
        return keystrokeChunks
    }
}

public struct FocusedTextInsertionPlanError: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
