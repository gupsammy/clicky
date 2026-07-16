import SwiftUI

struct CompanionSpatialInteractionPresentation: Equatable {
    let step: SpatialInteractionStep
    let label: String
    let capturedDisplayFrame: CGRect
    let displayRegion: CGRect
    let screenshotGeometry: SpatialScreenshotGeometry

    init?(
        descriptor: SpatialInteractionStepDescriptor,
        screenCapture: CompanionScreenCapture
    ) {
        guard descriptor.screenNumber == screenCapture.screenNumber else {
            return nil
        }

        let step: SpatialInteractionStep
        do {
            step = try SpatialInteractionStep(
                identifier: descriptor.label,
                displayIdentifier: screenCapture.displayIdentifier,
                region: descriptor.region,
                screenshotWidth: Double(screenCapture.screenshotWidthInPixels),
                screenshotHeight: Double(screenCapture.screenshotHeightInPixels),
                kind: descriptor.kind
            )
        } catch {
            return nil
        }

        let displayWidth = Double(screenCapture.displayWidthInPoints)
        let displayHeight = Double(screenCapture.displayHeightInPoints)
        let screenshotWidth = Double(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = Double(screenCapture.screenshotHeightInPixels)
        guard displayWidth > 0,
              displayHeight > 0,
              screenshotWidth > 0,
              screenshotHeight > 0 else {
            return nil
        }

        self.step = step
        self.label = descriptor.label
        self.capturedDisplayFrame = screenCapture.displayFrame
        self.displayRegion = CGRect(
            x: descriptor.region.x * displayWidth / screenshotWidth,
            y: descriptor.region.y * displayHeight / screenshotHeight,
            width: descriptor.region.width * displayWidth / screenshotWidth,
            height: descriptor.region.height * displayHeight / screenshotHeight
        )
        self.screenshotGeometry = SpatialScreenshotGeometry(
            displayIdentifier: screenCapture.displayIdentifier,
            globalDisplayFrame: SpatialInteractionRect(
                x: screenCapture.displayFrameInCoreGraphicsCoordinates.origin.x,
                y: screenCapture.displayFrameInCoreGraphicsCoordinates.origin.y,
                width: screenCapture.displayFrameInCoreGraphicsCoordinates.width,
                height: screenCapture.displayFrameInCoreGraphicsCoordinates.height
            ),
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            globalCoordinateOrigin: .topLeft
        )
    }
}

struct SpatialInteractionStepOverlayView: View {
    let presentation: CompanionSpatialInteractionPresentation

    private let interactionColor = Color(
        red: 1.0,
        green: 0.28,
        blue: 0.36
    )

    var body: some View {
        let isHoverStep: Bool = {
            if case .hover = presentation.step.kind {
                return true
            }
            return false
        }()

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(interactionColor.opacity(isHoverStep ? 0.08 : 0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            interactionColor,
                            style: StrokeStyle(
                                lineWidth: isHoverStep ? 3 : 4,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: isHoverStep ? [8, 6] : []
                            )
                        )
                }
                .shadow(
                    color: interactionColor.opacity(isHoverStep ? 0.35 : 0.62),
                    radius: isHoverStep ? 8 : 13
                )
                .frame(
                    width: presentation.displayRegion.width,
                    height: presentation.displayRegion.height
                )
                .position(
                    x: presentation.displayRegion.midX,
                    y: presentation.displayRegion.midY
                )

            Text(presentation.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(interactionColor)
                        .shadow(
                            color: interactionColor.opacity(0.48),
                            radius: 7
                        )
                )
                .fixedSize()
                .offset(
                    x: presentation.displayRegion.minX,
                    y: max(4, presentation.displayRegion.minY - 30)
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SpatialCursorTraceOverlayView: View {
    let samples: [SpatialCursorSample]
    let displayIdentifier: CGDirectDisplayID
    let globalDisplayFrame: CGRect
    let displaySize: CGSize

    private let traceColor = Color(
        red: 0.18,
        green: 0.88,
        blue: 1.0
    )

    var body: some View {
        let displayPoints = resolvedDisplayPoints
        if displayPoints.isEmpty {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) {
                timelineContext in
                Canvas { context, _ in
                    drawTrace(
                        displayPoints,
                        timelineDate: timelineContext.date,
                        in: &context
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var resolvedDisplayPoints: [CGPoint] {
        guard globalDisplayFrame.width > 0,
              globalDisplayFrame.height > 0,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return []
        }

        return samples.compactMap { sample in
            guard sample.displayIdentifier == displayIdentifier else {
                return nil
            }
            let globalPoint = CGPoint(
                x: sample.globalPoint.x,
                y: sample.globalPoint.y
            )
            guard globalDisplayFrame.contains(globalPoint) else {
                return nil
            }
            return CGPoint(
                x: (globalPoint.x - globalDisplayFrame.minX)
                    * displaySize.width / globalDisplayFrame.width,
                y: (globalPoint.y - globalDisplayFrame.minY)
                    * displaySize.height / globalDisplayFrame.height
            )
        }
    }

    private func drawTrace(
        _ displayPoints: [CGPoint],
        timelineDate: Date,
        in context: inout GraphicsContext
    ) {
        context.addFilter(
            .shadow(color: traceColor.opacity(0.75), radius: 7)
        )

        if displayPoints.count > 1 {
            var tracePath = Path()
            tracePath.move(to: displayPoints[0])
            for displayPoint in displayPoints.dropFirst() {
                tracePath.addLine(to: displayPoint)
            }
            context.stroke(
                tracePath,
                with: .color(traceColor.opacity(0.9)),
                style: StrokeStyle(
                    lineWidth: 3,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        guard let finalDisplayPoint = displayPoints.last else { return }
        let pulsePhase = timelineDate.timeIntervalSinceReferenceDate * 3.2
        let haloRadius = CGFloat(11 + (sin(pulsePhase) + 1) * 3)
        let haloRectangle = CGRect(
            x: finalDisplayPoint.x - haloRadius,
            y: finalDisplayPoint.y - haloRadius,
            width: haloRadius * 2,
            height: haloRadius * 2
        )
        context.fill(
            Path(ellipseIn: haloRectangle),
            with: .color(traceColor.opacity(0.13))
        )
        context.stroke(
            Path(ellipseIn: haloRectangle),
            with: .color(traceColor.opacity(0.9)),
            lineWidth: 2
        )
    }
}

struct CompanionSpatialAnnotation: Identifiable, Equatable {
    let id: Int
    let displayIdentifier: CGDirectDisplayID
    let capturedDisplayFrame: CGRect
    let sequenceNumber: Int
    let label: String?
    let kind: CompanionSpatialAnnotationKind

    /// `sequenceNumber` is the densified reveal-order position assigned by the
    /// caller after filtering, not `annotation.sequenceNumber` — filtered POINT
    /// tags would otherwise leave gaps that stall the Canvas reveal timeline.
    init?(
        annotation: SpatialAnnotation,
        screenCapture: CompanionScreenCapture,
        sequenceNumber: Int
    ) {
        let geometry = SpatialAnnotationDisplayGeometry(
            screenshotWidth: Double(screenCapture.screenshotWidthInPixels),
            screenshotHeight: Double(screenCapture.screenshotHeightInPixels),
            displayWidth: Double(screenCapture.displayWidthInPoints),
            displayHeight: Double(screenCapture.displayHeightInPoints)
        )
        guard let resolvedKind = CompanionSpatialAnnotationKind(
            annotationKind: annotation.kind,
            geometry: geometry
        ) else {
            return nil
        }

        id = sequenceNumber
        displayIdentifier = screenCapture.displayIdentifier
        capturedDisplayFrame = screenCapture.displayFrame
        self.sequenceNumber = sequenceNumber
        label = annotation.label
        kind = resolvedKind
    }
}

enum CompanionSpatialAnnotationKind: Equatable {
    case point(CGPoint)
    case highlight(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case circle(CGRect)
    case curve(start: CGPoint, control: CGPoint, end: CGPoint)
    case polygon(points: [CGPoint])

    init?(
        annotationKind: SpatialAnnotationKind,
        geometry: SpatialAnnotationDisplayGeometry
    ) {
        func resolve(_ point: SpatialAnnotationPoint) -> CGPoint? {
            guard let displayPoint = geometry.displayPoint(for: point) else {
                return nil
            }
            return CGPoint(x: displayPoint.x, y: displayPoint.y)
        }

        switch annotationKind {
        case .point(let point):
            guard let point = resolve(point) else { return nil }
            self = .point(point)
        case .highlight(let origin, let width, let height):
            guard let origin = resolve(origin),
                  let resolvedWidth = geometry.displayWidth(for: width),
                  let resolvedHeight = geometry.displayHeight(for: height),
                  origin.x + resolvedWidth <= geometry.displayWidth,
                  origin.y + resolvedHeight <= geometry.displayHeight else {
                return nil
            }
            self = .highlight(
                CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: resolvedWidth,
                    height: resolvedHeight
                )
            )
        case .line(let start, let end):
            guard let start = resolve(start), let end = resolve(end) else { return nil }
            self = .line(start: start, end: end)
        case .arrow(let start, let end):
            guard let start = resolve(start), let end = resolve(end) else { return nil }
            self = .arrow(start: start, end: end)
        case .circle(let topLeft, let bottomRight):
            guard let topLeft = resolve(topLeft),
                  let bottomRight = resolve(bottomRight) else {
                return nil
            }
            self = .circle(
                CGRect(
                    x: topLeft.x,
                    y: topLeft.y,
                    width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y
                )
            )
        case .curve(let start, let control, let end):
            guard let start = resolve(start),
                  let control = resolve(control),
                  let end = resolve(end) else {
                return nil
            }
            self = .curve(start: start, control: control, end: end)
        case .polygon(let points):
            let resolvedPoints = points.compactMap(resolve)
            guard resolvedPoints.count == points.count else { return nil }
            self = .polygon(points: resolvedPoints)
        }
    }

    var labelAnchor: CGPoint {
        switch self {
        case .point(let point):
            return point
        case .highlight(let rectangle), .circle(let rectangle):
            return CGPoint(x: rectangle.midX, y: rectangle.minY)
        case .line(_, let end), .arrow(_, let end), .curve(_, _, let end):
            return end
        case .polygon(let points):
            return points.first ?? .zero
        }
    }
}

struct SpatialAnnotationOverlayView: View {
    let annotations: [CompanionSpatialAnnotation]
    let maximumSequenceNumber: Int
    let sceneGeneration: Int
    @State private var visibleSequenceNumber = 0

    private let annotationColor = Color(
        red: 1.0,
        green: 0.22,
        blue: 0.38
    )

    var body: some View {
        Canvas { context, canvasSize in
            for annotation in annotations where annotation.sequenceNumber <= visibleSequenceNumber {
                context.drawLayer { annotationContext in
                    draw(annotation, in: &annotationContext, canvasSize: canvasSize)
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: sceneGeneration) {
            visibleSequenceNumber = 0
            guard !annotations.isEmpty, maximumSequenceNumber > 0 else { return }
            for nextSequenceNumber in 1...maximumSequenceNumber where !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                visibleSequenceNumber = nextSequenceNumber
            }
        }
    }

    private func draw(
        _ annotation: CompanionSpatialAnnotation,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        context.addFilter(
            .shadow(
                color: annotationColor.opacity(0.55),
                radius: 5
            )
        )

        switch annotation.kind {
        case .point(let point):
            let pointRectangle = CGRect(
                x: point.x - 9,
                y: point.y - 9,
                width: 18,
                height: 18
            )
            context.stroke(
                Path(ellipseIn: pointRectangle),
                with: .color(annotationColor),
                lineWidth: 3
            )
        case .highlight(let rectangle):
            context.fill(
                Path(roundedRect: rectangle, cornerRadius: 8),
                with: .color(annotationColor.opacity(0.15))
            )
            context.stroke(
                Path(roundedRect: rectangle, cornerRadius: 8),
                with: .color(annotationColor),
                lineWidth: 3
            )
        case .line(let start, let end):
            context.stroke(
                path(from: start, to: end),
                with: .color(annotationColor),
                lineWidth: 3
            )
        case .arrow(let start, let end):
            drawArrow(from: start, to: end, in: &context)
        case .circle(let rectangle):
            context.stroke(
                Path(ellipseIn: rectangle),
                with: .color(annotationColor),
                lineWidth: 3
            )
        case .curve(let start, let control, let end):
            var curvePath = Path()
            curvePath.move(to: start)
            curvePath.addQuadCurve(to: end, control: control)
            context.stroke(
                curvePath,
                with: .color(annotationColor),
                lineWidth: 3
            )
        case .polygon(let points):
            guard let firstPoint = points.first else { break }
            var polygonPath = Path()
            polygonPath.move(to: firstPoint)
            for point in points.dropFirst() {
                polygonPath.addLine(to: point)
            }
            polygonPath.closeSubpath()
            context.fill(
                polygonPath,
                with: .color(annotationColor.opacity(0.08))
            )
            context.stroke(
                polygonPath,
                with: .color(annotationColor),
                lineWidth: 3
            )
        }

        drawLabel(for: annotation, in: &context, canvasSize: canvasSize)
    }

    private func path(from start: CGPoint, to end: CGPoint) -> Path {
        var linePath = Path()
        linePath.move(to: start)
        linePath.addLine(to: end)
        return linePath
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        in context: inout GraphicsContext
    ) {
        context.stroke(
            path(from: start, to: end),
            with: .color(annotationColor),
            lineWidth: 3
        )
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowHeadLength: CGFloat = 14
        let arrowHeadAngle: CGFloat = .pi / 6
        let firstArrowHeadPoint = CGPoint(
            x: end.x - arrowHeadLength * cos(angle - arrowHeadAngle),
            y: end.y - arrowHeadLength * sin(angle - arrowHeadAngle)
        )
        let secondArrowHeadPoint = CGPoint(
            x: end.x - arrowHeadLength * cos(angle + arrowHeadAngle),
            y: end.y - arrowHeadLength * sin(angle + arrowHeadAngle)
        )
        var arrowHeadPath = Path()
        arrowHeadPath.move(to: firstArrowHeadPoint)
        arrowHeadPath.addLine(to: end)
        arrowHeadPath.addLine(to: secondArrowHeadPoint)
        context.stroke(
            arrowHeadPath,
            with: .color(annotationColor),
            lineWidth: 3
        )
    }

    private func drawLabel(
        for annotation: CompanionSpatialAnnotation,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        guard let label = annotation.label, !label.isEmpty else { return }
        let labelText = context.resolve(
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        )
        let measuredTextSize = labelText.measure(
            in: CGSize(width: 240, height: 40)
        )
        let labelSize = CGSize(
            width: measuredTextSize.width + 14,
            height: measuredTextSize.height + 8
        )
        let proposedOrigin = CGPoint(
            x: annotation.kind.labelAnchor.x - labelSize.width / 2,
            y: annotation.kind.labelAnchor.y - labelSize.height - 8
        )
        let labelRectangle = CGRect(
            x: min(max(proposedOrigin.x, 6), max(6, canvasSize.width - labelSize.width - 6)),
            y: min(max(proposedOrigin.y, 6), max(6, canvasSize.height - labelSize.height - 6)),
            width: labelSize.width,
            height: labelSize.height
        )
        context.fill(
            Path(roundedRect: labelRectangle, cornerRadius: 5),
            with: .color(annotationColor)
        )
        context.draw(
            labelText,
            at: CGPoint(x: labelRectangle.midX, y: labelRectangle.midY),
            anchor: .center
        )
    }
}
