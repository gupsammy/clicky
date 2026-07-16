import Foundation

public struct SpatialAnnotationPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum SpatialAnnotationKind: Equatable, Sendable {
    case point(SpatialAnnotationPoint)
    case highlight(origin: SpatialAnnotationPoint, width: Double, height: Double)
    case line(start: SpatialAnnotationPoint, end: SpatialAnnotationPoint)
    case arrow(start: SpatialAnnotationPoint, end: SpatialAnnotationPoint)
    case circle(topLeft: SpatialAnnotationPoint, bottomRight: SpatialAnnotationPoint)
    case curve(
        start: SpatialAnnotationPoint,
        control: SpatialAnnotationPoint,
        end: SpatialAnnotationPoint
    )
    case polygon(points: [SpatialAnnotationPoint])
}

public struct SpatialAnnotation: Equatable, Sendable {
    public let sequenceNumber: Int
    public let screenNumber: Int?
    public let label: String?
    public let kind: SpatialAnnotationKind

    public init(
        sequenceNumber: Int,
        screenNumber: Int?,
        label: String?,
        kind: SpatialAnnotationKind
    ) {
        self.sequenceNumber = sequenceNumber
        self.screenNumber = screenNumber
        self.label = label
        self.kind = kind
    }
}

public struct SpatialAnnotationParseResult: Equatable, Sendable {
    public let spokenText: String
    public let annotations: [SpatialAnnotation]

    public init(spokenText: String, annotations: [SpatialAnnotation]) {
        self.spokenText = spokenText
        self.annotations = annotations
    }
}

public enum SpatialAnnotationParser {
    public static let maximumAnnotationCount = 12
    public static let maximumPolygonPointCount = 32

    public static func parse(_ responseText: String) -> SpatialAnnotationParseResult {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"\[(POINT|HIGHLIGHT|SHAPE):([^\]\r\n]*)\]"#,
            options: [.caseInsensitive]
        ) else {
            return SpatialAnnotationParseResult(
                spokenText: responseText,
                annotations: []
            )
        }

        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = tagRegex.matches(in: responseText, range: responseRange)
        var parsedAnnotations: [SpatialAnnotation] = []

        for match in matches where parsedAnnotations.count < maximumAnnotationCount {
            guard let commandRange = Range(match.range(at: 1), in: responseText),
                  let bodyRange = Range(match.range(at: 2), in: responseText) else {
                continue
            }
            let command = responseText[commandRange].uppercased()
            let body = String(responseText[bodyRange])
            let sequenceNumber = parsedAnnotations.count + 1

            let parsedAnnotation: SpatialAnnotation?
            switch command {
            case "POINT":
                parsedAnnotation = parsePoint(
                    body,
                    sequenceNumber: sequenceNumber
                )
            case "HIGHLIGHT":
                parsedAnnotation = parseHighlight(
                    body,
                    sequenceNumber: sequenceNumber
                )
            case "SHAPE":
                parsedAnnotation = parseShape(
                    body,
                    sequenceNumber: sequenceNumber
                )
            default:
                parsedAnnotation = nil
            }

            if let parsedAnnotation {
                parsedAnnotations.append(parsedAnnotation)
            }
        }

        let spokenText = removingTags(
            from: responseText,
            matches: matches
        )
        return SpatialAnnotationParseResult(
            spokenText: spokenText,
            annotations: parsedAnnotations
        )
    }

    private static func parsePoint(
        _ body: String,
        sequenceNumber: Int
    ) -> SpatialAnnotation? {
        if body.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("none") == .orderedSame {
            return nil
        }

        var components = body.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        let screenSuffix = removeScreenNumber(from: &components)
        guard screenSuffix.isValid,
              let coordinateComponent = components.first,
              let point = parsePointComponent(coordinateComponent) else {
            return nil
        }

        let label = sanitizedLabel(from: components.dropFirst())
        return SpatialAnnotation(
            sequenceNumber: sequenceNumber,
            screenNumber: screenSuffix.screenNumber,
            label: label,
            kind: .point(point)
        )
    }

    private static func parseHighlight(
        _ body: String,
        sequenceNumber: Int
    ) -> SpatialAnnotation? {
        var components = body.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        let screenSuffix = removeScreenNumber(from: &components)
        guard screenSuffix.isValid,
              let geometryComponent = components.first,
              let values = parseNumbers(geometryComponent, expectedCount: 4),
              values[2] > 0,
              values[3] > 0 else {
            return nil
        }

        return SpatialAnnotation(
            sequenceNumber: sequenceNumber,
            screenNumber: screenSuffix.screenNumber,
            label: sanitizedLabel(from: components.dropFirst()),
            kind: .highlight(
                origin: SpatialAnnotationPoint(x: values[0], y: values[1]),
                width: values[2],
                height: values[3]
            )
        )
    }

    private static func parseShape(
        _ body: String,
        sequenceNumber: Int
    ) -> SpatialAnnotation? {
        var components = body.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        let screenSuffix = removeScreenNumber(from: &components)
        guard screenSuffix.isValid, components.count >= 2 else {
            return nil
        }

        let shapeName = components.removeFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let geometry = components.removeFirst()
        let label = sanitizedLabel(from: components[...])
        let kind: SpatialAnnotationKind?

        switch shapeName {
        case "line", "arrow":
            guard let points = parsePointList(geometry), points.count == 2 else {
                return nil
            }
            kind = shapeName == "line"
                ? .line(start: points[0], end: points[1])
                : .arrow(start: points[0], end: points[1])
        case "circle":
            guard let points = parsePointList(geometry),
                  points.count == 2,
                  points[1].x > points[0].x,
                  points[1].y > points[0].y else {
                return nil
            }
            kind = .circle(
                topLeft: points[0],
                bottomRight: points[1]
            )
        case "curve":
            guard let points = parsePointList(geometry), points.count == 3 else {
                return nil
            }
            kind = .curve(
                start: points[0],
                control: points[1],
                end: points[2]
            )
        case "polygon":
            guard let points = parsePointList(geometry),
                  points.count >= 3,
                  points.count <= maximumPolygonPointCount else {
                return nil
            }
            kind = .polygon(points: points)
        default:
            kind = nil
        }

        guard let kind else { return nil }
        return SpatialAnnotation(
            sequenceNumber: sequenceNumber,
            screenNumber: screenSuffix.screenNumber,
            label: label,
            kind: kind
        )
    }

    private static func parsePointList(
        _ geometry: String
    ) -> [SpatialAnnotationPoint]? {
        let pointComponents = geometry.split(
            separator: ";",
            omittingEmptySubsequences: true
        )
        guard !pointComponents.isEmpty else { return nil }

        let points = pointComponents.compactMap {
            parsePointComponent(String($0))
        }
        return points.count == pointComponents.count ? points : nil
    }

    private static func parsePointComponent(
        _ component: String
    ) -> SpatialAnnotationPoint? {
        guard let values = parseNumbers(component, expectedCount: 2) else {
            return nil
        }
        return SpatialAnnotationPoint(x: values[0], y: values[1])
    }

    private static func parseNumbers(
        _ component: String,
        expectedCount: Int
    ) -> [Double]? {
        let numberComponents = component.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard numberComponents.count == expectedCount else { return nil }

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
        return values.count == expectedCount ? values : nil
    }

    private static func removeScreenNumber(
        from components: inout [String]
    ) -> (screenNumber: Int?, isValid: Bool) {
        guard let lastComponent = components.last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return (nil, true)
        }
        guard lastComponent.hasPrefix("screen") else { return (nil, true) }
        guard let screenNumber = Int(lastComponent.dropFirst("screen".count)),
              (1...16).contains(screenNumber) else {
            return (nil, false)
        }
        components.removeLast()
        return (screenNumber, true)
    }

    private static func sanitizedLabel<Components: Collection>(
        from components: Components
    ) -> String? where Components.Element == String {
        let joinedLabel = components.joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinedLabel.isEmpty else { return nil }
        return String(joinedLabel.prefix(48))
    }

    private static func removingTags(
        from responseText: String,
        matches: [NSTextCheckingResult]
    ) -> String {
        var spokenText = responseText
        for match in matches.reversed() {
            guard let tagRange = Range(match.range, in: spokenText) else { continue }
            spokenText.removeSubrange(tagRange)
        }
        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SpatialAnnotationDisplayGeometry: Equatable, Sendable {
    public let screenshotWidth: Double
    public let screenshotHeight: Double
    public let displayWidth: Double
    public let displayHeight: Double

    public init(
        screenshotWidth: Double,
        screenshotHeight: Double,
        displayWidth: Double,
        displayHeight: Double
    ) {
        self.screenshotWidth = screenshotWidth
        self.screenshotHeight = screenshotHeight
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    public func displayPoint(
        for screenshotPoint: SpatialAnnotationPoint
    ) -> SpatialAnnotationPoint? {
        guard screenshotWidth > 0,
              screenshotHeight > 0,
              displayWidth > 0,
              displayHeight > 0 else {
            return nil
        }
        guard (0...screenshotWidth).contains(screenshotPoint.x),
              (0...screenshotHeight).contains(screenshotPoint.y) else {
            return nil
        }
        return SpatialAnnotationPoint(
            x: screenshotPoint.x * displayWidth / screenshotWidth,
            y: screenshotPoint.y * displayHeight / screenshotHeight
        )
    }

    public func displayWidth(for screenshotWidth: Double) -> Double? {
        guard self.screenshotWidth > 0, displayWidth > 0 else { return nil }
        return max(0, screenshotWidth) * displayWidth / self.screenshotWidth
    }

    public func displayHeight(for screenshotHeight: Double) -> Double? {
        guard self.screenshotHeight > 0, displayHeight > 0 else { return nil }
        return max(0, screenshotHeight) * displayHeight / self.screenshotHeight
    }
}

public enum SpatialAnnotationScreenResolver {
    public static func resolvedScreenNumber(
        requestedScreenNumber: Int?,
        availableScreenNumbers: [Int],
        cursorScreenNumber: Int?
    ) -> Int? {
        if let requestedScreenNumber {
            return availableScreenNumbers.contains(requestedScreenNumber)
                ? requestedScreenNumber
                : nil
        }
        guard let cursorScreenNumber,
              availableScreenNumbers.contains(cursorScreenNumber) else {
            return nil
        }
        return cursorScreenNumber
    }
}
