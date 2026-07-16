import SwiftUI

struct CompanionSpatialAnnotation: Identifiable, Equatable {
    let id: Int
    let displayIdentifier: CGDirectDisplayID
    let capturedDisplayFrame: CGRect
    let sequenceNumber: Int
    let label: String?
    let kind: CompanionSpatialAnnotationKind

    init?(
        annotation: SpatialAnnotation,
        screenCapture: CompanionScreenCapture
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

        id = annotation.sequenceNumber
        displayIdentifier = screenCapture.displayIdentifier
        capturedDisplayFrame = screenCapture.displayFrame
        sequenceNumber = annotation.sequenceNumber
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
