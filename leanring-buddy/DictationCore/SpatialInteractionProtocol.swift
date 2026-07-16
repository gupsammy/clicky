import Foundation

public struct SpatialInteractionPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    fileprivate var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

public struct SpatialInteractionRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: SpatialInteractionPoint) -> Bool {
        guard isValid, point.isFinite else { return false }
        return point.x >= x
            && point.x <= x + width
            && point.y >= y
            && point.y <= y + height
    }

    fileprivate var isValid: Bool {
        x.isFinite
            && y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}

public struct SpatialCursorSample: Equatable, Sendable {
    public let displayIdentifier: UInt32
    public let globalPoint: SpatialInteractionPoint
    public let timestamp: TimeInterval

    public init(
        displayIdentifier: UInt32,
        globalPoint: SpatialInteractionPoint,
        timestamp: TimeInterval
    ) {
        self.displayIdentifier = displayIdentifier
        self.globalPoint = globalPoint
        self.timestamp = timestamp
    }

    fileprivate var isValid: Bool {
        globalPoint.isFinite && timestamp.isFinite && timestamp >= 0
    }
}

public enum SpatialGlobalCoordinateOrigin: Equatable, Sendable {
    case topLeft
    case bottomLeft
}

public struct SpatialScreenshotGeometry: Equatable, Sendable {
    public let displayIdentifier: UInt32
    public let globalDisplayFrame: SpatialInteractionRect
    public let screenshotWidth: Double
    public let screenshotHeight: Double
    public let globalCoordinateOrigin: SpatialGlobalCoordinateOrigin

    public init(
        displayIdentifier: UInt32,
        globalDisplayFrame: SpatialInteractionRect,
        screenshotWidth: Double,
        screenshotHeight: Double,
        globalCoordinateOrigin: SpatialGlobalCoordinateOrigin
    ) {
        self.displayIdentifier = displayIdentifier
        self.globalDisplayFrame = globalDisplayFrame
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.globalCoordinateOrigin = globalCoordinateOrigin
    }

    public func screenshotPoint(
        for sample: SpatialCursorSample
    ) -> SpatialInteractionPoint? {
        guard sample.isValid,
              sample.displayIdentifier == displayIdentifier,
              globalDisplayFrame.isValid,
              screenshotWidth.isFinite,
              screenshotHeight.isFinite,
              screenshotWidth > 0,
              screenshotHeight > 0,
              globalDisplayFrame.contains(sample.globalPoint) else {
            return nil
        }

        let displayRelativeX = sample.globalPoint.x - globalDisplayFrame.x
        let displayRelativeY: Double
        switch globalCoordinateOrigin {
        case .topLeft:
            displayRelativeY = sample.globalPoint.y - globalDisplayFrame.y
        case .bottomLeft:
            displayRelativeY = globalDisplayFrame.y
                + globalDisplayFrame.height
                - sample.globalPoint.y
        }

        return SpatialInteractionPoint(
            x: displayRelativeX * screenshotWidth / globalDisplayFrame.width,
            y: displayRelativeY * screenshotHeight / globalDisplayFrame.height
        )
    }
}

public struct SpatialTracePoint: Equatable, Sendable {
    public let point: SpatialInteractionPoint
    public let elapsedTime: TimeInterval

    public init(point: SpatialInteractionPoint, elapsedTime: TimeInterval) {
        self.point = point
        self.elapsedTime = elapsedTime
    }
}

public struct SpatialHoverSummary: Equatable, Sendable {
    public let point: SpatialInteractionPoint
    public let duration: TimeInterval

    public init(point: SpatialInteractionPoint, duration: TimeInterval) {
        self.point = point
        self.duration = duration
    }
}

public struct SpatialTraceSummary: Equatable, Sendable {
    public let displayIdentifier: UInt32
    public let tracePoints: [SpatialTracePoint]
    public let hover: SpatialHoverSummary?

    public init(
        displayIdentifier: UInt32,
        tracePoints: [SpatialTracePoint],
        hover: SpatialHoverSummary?
    ) {
        self.displayIdentifier = displayIdentifier
        self.tracePoints = tracePoints
        self.hover = hover
    }

    public var modelDescription: String {
        let traceDescription = tracePoints.map { tracePoint in
            let x = Int(tracePoint.point.x.rounded())
            let y = Int(tracePoint.point.y.rounded())
            let milliseconds = Int((tracePoint.elapsedTime * 1_000).rounded())
            return "(\(x),\(y) @ \(milliseconds)ms)"
        }.joined(separator: " -> ")

        var description = "Cursor trace on display \(displayIdentifier)"
            + " in attached screenshot pixels: \(traceDescription)."
        if let hover {
            let hoverX = Int(hover.point.x.rounded())
            let hoverY = Int(hover.point.y.rounded())
            let hoverMilliseconds = Int((hover.duration * 1_000).rounded())
            description += " Final hover near (\(hoverX),\(hoverY))"
                + " for \(hoverMilliseconds)ms."
        }
        return description
    }
}

public struct SpatialCursorTrace: Equatable, Sendable {
    public static let defaultMaximumSampleCount = 64
    public static let defaultMaximumSummaryPointCount = 24

    public let maximumSampleCount: Int
    public private(set) var samples: [SpatialCursorSample]

    public init(maximumSampleCount: Int = defaultMaximumSampleCount) {
        self.maximumSampleCount = max(2, maximumSampleCount)
        self.samples = []
    }

    public mutating func record(_ sample: SpatialCursorSample) {
        guard sample.isValid,
              samples.last.map({ sample.timestamp >= $0.timestamp }) ?? true else {
            return
        }

        samples.append(sample)
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }
    }

    public func summary(
        for geometry: SpatialScreenshotGeometry,
        maximumTracePointCount: Int = defaultMaximumSummaryPointCount,
        hoverRadiusInScreenshotPixels: Double = 18
    ) -> SpatialTraceSummary? {
        guard !samples.isEmpty,
              maximumTracePointCount > 0,
              hoverRadiusInScreenshotPixels.isFinite,
              hoverRadiusInScreenshotPixels >= 0,
              samples.allSatisfy({
                  $0.displayIdentifier == geometry.displayIdentifier
              }) else {
            return nil
        }

        let normalizedSamples = samples.compactMap { sample -> SpatialTracePoint? in
            guard let screenshotPoint = geometry.screenshotPoint(for: sample),
                  let firstTimestamp = samples.first?.timestamp else {
                return nil
            }
            return SpatialTracePoint(
                point: screenshotPoint,
                elapsedTime: sample.timestamp - firstTimestamp
            )
        }
        guard normalizedSamples.count == samples.count else { return nil }

        let summaryPoints = Self.evenlySpacedPoints(
            normalizedSamples,
            maximumCount: maximumTracePointCount
        )
        let hover = Self.hoverSummary(
            from: normalizedSamples,
            radius: hoverRadiusInScreenshotPixels
        )
        return SpatialTraceSummary(
            displayIdentifier: geometry.displayIdentifier,
            tracePoints: summaryPoints,
            hover: hover
        )
    }

    private static func evenlySpacedPoints(
        _ points: [SpatialTracePoint],
        maximumCount: Int
    ) -> [SpatialTracePoint] {
        guard points.count > maximumCount else { return points }
        guard maximumCount > 1 else { return [points[points.count - 1]] }

        return (0..<maximumCount).map { outputIndex in
            let inputIndex = outputIndex * (points.count - 1)
                / (maximumCount - 1)
            return points[inputIndex]
        }
    }

    private static func hoverSummary(
        from points: [SpatialTracePoint],
        radius: Double
    ) -> SpatialHoverSummary? {
        guard let finalPoint = points.last else { return nil }

        var hoverStartIndex = points.count - 1
        while hoverStartIndex > 0 {
            let candidateIndex = hoverStartIndex - 1
            guard distance(
                from: points[candidateIndex].point,
                to: finalPoint.point
            ) <= radius else {
                break
            }
            hoverStartIndex = candidateIndex
        }

        let duration = finalPoint.elapsedTime
            - points[hoverStartIndex].elapsedTime
        guard duration > 0 else { return nil }
        return SpatialHoverSummary(
            point: finalPoint.point,
            duration: duration
        )
    }

    private static func distance(
        from firstPoint: SpatialInteractionPoint,
        to secondPoint: SpatialInteractionPoint
    ) -> Double {
        hypot(
            firstPoint.x - secondPoint.x,
            firstPoint.y - secondPoint.y
        )
    }
}

public enum SpatialInteractionStepKind: Equatable, Sendable {
    case target
    case hover(minimumDuration: TimeInterval)
}

public struct SpatialInteractionStepDescriptor: Equatable, Sendable {
    public let screenNumber: Int
    public let region: SpatialInteractionRect
    public let label: String
    public let kind: SpatialInteractionStepKind

    public init(
        screenNumber: Int,
        region: SpatialInteractionRect,
        label: String,
        kind: SpatialInteractionStepKind
    ) {
        self.screenNumber = screenNumber
        self.region = region
        self.label = label
        self.kind = kind
    }
}

public struct SpatialInteractionParseResult: Equatable, Sendable {
    public let spokenText: String
    public let step: SpatialInteractionStepDescriptor?

    public init(
        spokenText: String,
        step: SpatialInteractionStepDescriptor?
    ) {
        self.spokenText = spokenText
        self.step = step
    }
}

public enum SpatialInteractionTagParser {
    public static let maximumInteractiveTagCount = 12
    public static let maximumLabelCharacterCount = 100
    public static let hoverDwellDuration: TimeInterval = 0.65

    public static func parse(_ responseText: String) -> SpatialInteractionParseResult {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"\[(TARGET|HOVER):([^\]\r\n]*)\]"#,
            options: [.caseInsensitive]
        ) else {
            return SpatialInteractionParseResult(
                spokenText: responseText,
                step: nil
            )
        }

        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = tagRegex.matches(in: responseText, range: responseRange)
        var firstValidStep: SpatialInteractionStepDescriptor?

        for match in matches.prefix(maximumInteractiveTagCount) {
            guard firstValidStep == nil,
                  let commandRange = Range(match.range(at: 1), in: responseText),
                  let bodyRange = Range(match.range(at: 2), in: responseText) else {
                continue
            }
            firstValidStep = parseStep(
                command: responseText[commandRange].uppercased(),
                body: String(responseText[bodyRange])
            )
        }

        return SpatialInteractionParseResult(
            spokenText: removingKnownTags(
                from: responseText,
                matches: matches
            ),
            step: firstValidStep
        )
    }

    private static func parseStep(
        command: String,
        body: String
    ) -> SpatialInteractionStepDescriptor? {
        var components = body.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 3,
              let screenNumber = removeRequiredScreenNumber(
                  from: &components
              ),
              let geometryComponent = components.first,
              let region = parseRegion(geometryComponent),
              let label = sanitizedLabel(from: components.dropFirst()) else {
            return nil
        }

        let kind: SpatialInteractionStepKind
        switch command {
        case "TARGET":
            kind = .target
        case "HOVER":
            kind = .hover(minimumDuration: hoverDwellDuration)
        default:
            return nil
        }

        return SpatialInteractionStepDescriptor(
            screenNumber: screenNumber,
            region: region,
            label: label,
            kind: kind
        )
    }

    private static func parseRegion(
        _ geometryComponent: String
    ) -> SpatialInteractionRect? {
        let numberComponents = geometryComponent.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard numberComponents.count == 4 else { return nil }

        let values = numberComponents.compactMap { numberComponent -> Double? in
            let trimmedNumber = numberComponent.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let value = Double(trimmedNumber),
                  value.isFinite,
                  abs(value) <= 1_000_000 else {
                return nil
            }
            return value
        }
        guard values.count == 4,
              values[0] >= 0,
              values[1] >= 0,
              values[2] > 0,
              values[3] > 0 else {
            return nil
        }

        return SpatialInteractionRect(
            x: values[0],
            y: values[1],
            width: values[2],
            height: values[3]
        )
    }

    private static func removeRequiredScreenNumber(
        from components: inout [String]
    ) -> Int? {
        guard let screenComponent = components.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              screenComponent.hasPrefix("screen"),
              let screenNumber = Int(
                  screenComponent.dropFirst("screen".count)
              ),
              (1...16).contains(screenNumber) else {
            return nil
        }
        components.removeLast()
        return screenNumber
    }

    private static func sanitizedLabel<Components: Collection>(
        from components: Components
    ) -> String? where Components.Element == String {
        let joinedLabel = components.joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinedLabel.isEmpty else { return nil }
        return String(joinedLabel.prefix(maximumLabelCharacterCount))
    }

    private static func removingKnownTags(
        from responseText: String,
        matches: [NSTextCheckingResult]
    ) -> String {
        var spokenText = responseText
        for match in matches.reversed() {
            guard let tagRange = Range(match.range, in: spokenText) else {
                continue
            }
            spokenText.removeSubrange(tagRange)
        }
        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SpatialInteractionStep: Equatable, Sendable {
    public let identifier: String
    public let displayIdentifier: UInt32
    public let region: SpatialInteractionRect
    public let kind: SpatialInteractionStepKind

    public init(
        identifier: String,
        displayIdentifier: UInt32,
        region: SpatialInteractionRect,
        screenshotWidth: Double,
        screenshotHeight: Double,
        kind: SpatialInteractionStepKind
    ) throws {
        let trimmedIdentifier = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedIdentifier.isEmpty,
              trimmedIdentifier.count <= 100,
              screenshotWidth.isFinite,
              screenshotHeight.isFinite,
              screenshotWidth > 0,
              screenshotHeight > 0,
              region.isValid,
              region.x >= 0,
              region.y >= 0,
              region.x + region.width <= screenshotWidth,
              region.y + region.height <= screenshotHeight else {
            throw SpatialInteractionProtocolError(
                message: "The spatial interaction step is outside the screenshot."
            )
        }

        if case let .hover(minimumDuration) = kind {
            guard minimumDuration.isFinite, minimumDuration > 0 else {
                throw SpatialInteractionProtocolError(
                    message: "A hover step requires a positive duration."
                )
            }
        }

        self.identifier = trimmedIdentifier
        self.displayIdentifier = displayIdentifier
        self.region = region
        self.kind = kind
    }
}

public enum SpatialInteractionEvent: Equatable, Sendable {
    case click(
        displayIdentifier: UInt32,
        screenshotPoint: SpatialInteractionPoint
    )
    case hover(
        displayIdentifier: UInt32,
        screenshotPoint: SpatialInteractionPoint,
        duration: TimeInterval
    )
}

public enum SpatialInteractionProgress: Equatable, Sendable {
    case waiting
    case completed
}

public struct SpatialInteractionTransition: Equatable, Sendable {
    public let progress: SpatialInteractionProgress
    public let didAdvance: Bool

    public init(progress: SpatialInteractionProgress, didAdvance: Bool) {
        self.progress = progress
        self.didAdvance = didAdvance
    }
}

public enum SpatialInteractionReducer {
    public static func reduce(
        progress: SpatialInteractionProgress,
        step: SpatialInteractionStep,
        event: SpatialInteractionEvent
    ) -> SpatialInteractionTransition {
        guard progress == .waiting else {
            return SpatialInteractionTransition(
                progress: .completed,
                didAdvance: false
            )
        }

        let eventMatchesStep: Bool
        switch (step.kind, event) {
        case let (
            .target,
            .click(displayIdentifier, screenshotPoint)
        ):
            eventMatchesStep = displayIdentifier == step.displayIdentifier
                && step.region.contains(screenshotPoint)
        case let (
            .hover(minimumDuration),
            .hover(displayIdentifier, screenshotPoint, duration)
        ):
            eventMatchesStep = displayIdentifier == step.displayIdentifier
                && duration.isFinite
                && duration >= minimumDuration
                && step.region.contains(screenshotPoint)
        default:
            eventMatchesStep = false
        }

        guard eventMatchesStep else {
            return SpatialInteractionTransition(
                progress: .waiting,
                didAdvance: false
            )
        }
        return SpatialInteractionTransition(
            progress: .completed,
            didAdvance: true
        )
    }
}

public struct SpatialInteractionProtocolError: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
