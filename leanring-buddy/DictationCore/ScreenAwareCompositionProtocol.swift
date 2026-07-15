import CoreGraphics
import Foundation

public struct ScreenAwareCompositionRequest: Codable, Equatable, Sendable {
    public let spokenInstruction: String
    public let applicationName: String?
    public let windowTitle: String?
    public let selectedText: String?
    public let textBeforeSelection: String?
    public let textAfterSelection: String?
    public let screenshotJPEGBase64: String

    public init(
        spokenInstruction: String,
        applicationName: String?,
        windowTitle: String?,
        selectedText: String?,
        textBeforeSelection: String?,
        textAfterSelection: String?,
        screenshotJPEGData: Data
    ) throws {
        let trimmedInstruction = spokenInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw ScreenAwareCompositionProtocolError(
                message: "Screen-aware dictation requires a spoken instruction."
            )
        }
        guard !screenshotJPEGData.isEmpty else {
            throw ScreenAwareCompositionProtocolError(
                message: "Screen-aware dictation requires a screenshot."
            )
        }
        guard screenshotJPEGData.count <= 4_500_000 else {
            throw ScreenAwareCompositionProtocolError(
                message: "The screen-aware dictation screenshot is too large."
            )
        }

        self.spokenInstruction = String(trimmedInstruction.prefix(4_000))
        self.applicationName = Self.bounded(applicationName, limit: 300)
        self.windowTitle = Self.bounded(windowTitle, limit: 500)
        self.selectedText = Self.bounded(selectedText, limit: 8_000)
        self.textBeforeSelection = Self.bounded(textBeforeSelection, limit: 8_000)
        self.textAfterSelection = Self.bounded(textAfterSelection, limit: 8_000)
        self.screenshotJPEGBase64 = screenshotJPEGData.base64EncodedString()
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        return String(trimmedValue.prefix(limit))
    }
}

public struct ScreenAwareCompositionResponse: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ScreenAwareCompositionProtocolError(
                message: "OpenAI returned an empty screen-aware composition."
            )
        }
        guard trimmedText.count <= 20_000 else {
            throw ScreenAwareCompositionProtocolError(
                message: "OpenAI returned a screen-aware composition that is too large."
            )
        }
        self.text = trimmedText
    }

    public static func decode(data: Data) throws -> ScreenAwareCompositionResponse {
        let decodedResponse = try JSONDecoder().decode(
            ScreenAwareCompositionResponse.self,
            from: data
        )
        return try ScreenAwareCompositionResponse(text: decodedResponse.text)
    }
}

public struct ScreenAwareCompositionProtocolError: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum ScreenAwareDisplaySelector {
    public static func displayIndex(
        containing focusedElementFrame: CGRect,
        displayFrames: [CGRect]
    ) -> Int? {
        guard !displayFrames.isEmpty else { return nil }

        let focusedElementCenter = CGPoint(
            x: focusedElementFrame.midX,
            y: focusedElementFrame.midY
        )
        if let containingDisplayIndex = displayFrames.firstIndex(
            where: { $0.contains(focusedElementCenter) }
        ) {
            return containingDisplayIndex
        }

        let largestIntersection = displayFrames.enumerated()
            .map { displayIndex, displayFrame in
                (
                    displayIndex: displayIndex,
                    area: displayFrame.intersection(focusedElementFrame).area
                )
            }
            .max { firstResult, secondResult in
                firstResult.area < secondResult.area
            }
        if let largestIntersection, largestIntersection.area > 0 {
            return largestIntersection.displayIndex
        }

        return nil
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
