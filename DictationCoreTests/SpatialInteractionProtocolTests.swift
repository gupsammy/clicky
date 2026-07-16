import Testing
@testable import ClickyDictationCore

@Test func cursorTraceKeepsTheNewestBoundedSamples() {
    var trace = SpatialCursorTrace(maximumSampleCount: 3)

    for sampleIndex in 0..<5 {
        trace.record(
            SpatialCursorSample(
                displayIdentifier: 7,
                globalPoint: SpatialInteractionPoint(
                    x: Double(sampleIndex),
                    y: Double(sampleIndex)
                ),
                timestamp: Double(sampleIndex)
            )
        )
    }
    trace.record(
        SpatialCursorSample(
            displayIdentifier: 7,
            globalPoint: SpatialInteractionPoint(x: 100, y: 100),
            timestamp: 1
        )
    )

    #expect(trace.samples.map(\.timestamp) == [2, 3, 4])
}

@Test func cursorSamplesNormalizeFromGlobalBottomLeftToScreenshotTopLeft() {
    let geometry = SpatialScreenshotGeometry(
        displayIdentifier: 7,
        globalDisplayFrame: SpatialInteractionRect(
            x: 1_000,
            y: 200,
            width: 500,
            height: 400
        ),
        screenshotWidth: 1_000,
        screenshotHeight: 800,
        globalCoordinateOrigin: .bottomLeft
    )

    #expect(
        geometry.screenshotPoint(
            for: SpatialCursorSample(
                displayIdentifier: 7,
                globalPoint: SpatialInteractionPoint(x: 1_125, y: 500),
                timestamp: 0
            )
        ) == SpatialInteractionPoint(x: 250, y: 200)
    )
    #expect(
        geometry.screenshotPoint(
            for: SpatialCursorSample(
                displayIdentifier: 8,
                globalPoint: SpatialInteractionPoint(x: 1_125, y: 500),
                timestamp: 0
            )
        ) == nil
    )
    #expect(
        geometry.screenshotPoint(
            for: SpatialCursorSample(
                displayIdentifier: 7,
                globalPoint: SpatialInteractionPoint(x: 1_600, y: 500),
                timestamp: 0
            )
        ) == nil
    )
}

@Test func traceSummaryIsBoundedAndIncludesFinalHover() throws {
    let geometry = SpatialScreenshotGeometry(
        displayIdentifier: 7,
        globalDisplayFrame: SpatialInteractionRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: 500
        ),
        screenshotWidth: 1_000,
        screenshotHeight: 500,
        globalCoordinateOrigin: .topLeft
    )
    var trace = SpatialCursorTrace(maximumSampleCount: 64)
    for sampleIndex in 0..<30 {
        let point: SpatialInteractionPoint
        if sampleIndex >= 25 {
            point = SpatialInteractionPoint(
                x: 500 + Double(sampleIndex - 25),
                y: 200
            )
        } else {
            point = SpatialInteractionPoint(
                x: Double(sampleIndex * 20),
                y: 100
            )
        }
        trace.record(
            SpatialCursorSample(
                displayIdentifier: 7,
                globalPoint: point,
                timestamp: Double(sampleIndex) * 0.1
            )
        )
    }

    let summary = try #require(
        trace.summary(
            for: geometry,
            maximumTracePointCount: 6,
            hoverRadiusInScreenshotPixels: 10
        )
    )

    #expect(summary.tracePoints.count == 6)
    #expect(summary.tracePoints.first?.point == SpatialInteractionPoint(x: 0, y: 100))
    #expect(summary.tracePoints.last?.point == SpatialInteractionPoint(x: 504, y: 200))
    #expect(summary.hover?.point == SpatialInteractionPoint(x: 504, y: 200))
    #expect(abs((summary.hover?.duration ?? 0) - 0.4) < 0.000_001)
    #expect(summary.modelDescription.contains("display 7"))
    #expect(summary.modelDescription.contains("Final hover"))
}

@Test func traceSummaryFailsClosedAcrossDisplaysOrOutsideTheScreenshot() {
    let geometry = SpatialScreenshotGeometry(
        displayIdentifier: 7,
        globalDisplayFrame: SpatialInteractionRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: 500
        ),
        screenshotWidth: 1_000,
        screenshotHeight: 500,
        globalCoordinateOrigin: .topLeft
    )
    var crossDisplayTrace = SpatialCursorTrace()
    crossDisplayTrace.record(
        SpatialCursorSample(
            displayIdentifier: 7,
            globalPoint: SpatialInteractionPoint(x: 10, y: 10),
            timestamp: 0
        )
    )
    crossDisplayTrace.record(
        SpatialCursorSample(
            displayIdentifier: 8,
            globalPoint: SpatialInteractionPoint(x: 20, y: 20),
            timestamp: 0.1
        )
    )
    var outsideTrace = SpatialCursorTrace()
    outsideTrace.record(
        SpatialCursorSample(
            displayIdentifier: 7,
            globalPoint: SpatialInteractionPoint(x: 1_100, y: 20),
            timestamp: 0
        )
    )

    #expect(crossDisplayTrace.summary(for: geometry) == nil)
    #expect(outsideTrace.summary(for: geometry) == nil)
}

@Test func targetStepAdvancesOnceOnlyForAClickInsideTheExpectedDisplay() throws {
    let step = try SpatialInteractionStep(
        identifier: "open-menu",
        displayIdentifier: 7,
        region: SpatialInteractionRect(x: 100, y: 200, width: 80, height: 40),
        screenshotWidth: 1_000,
        screenshotHeight: 500,
        kind: .target
    )

    let wrongDisplay = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .click(
            displayIdentifier: 8,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220)
        )
    )
    let outsideRegion = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .click(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 500, y: 220)
        )
    )
    let completion = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .click(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220)
        )
    )
    let repeatedCompletion = SpatialInteractionReducer.reduce(
        progress: completion.progress,
        step: step,
        event: .click(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220)
        )
    )

    #expect(wrongDisplay == SpatialInteractionTransition(
        progress: .waiting,
        didAdvance: false
    ))
    #expect(outsideRegion == SpatialInteractionTransition(
        progress: .waiting,
        didAdvance: false
    ))
    #expect(completion == SpatialInteractionTransition(
        progress: .completed,
        didAdvance: true
    ))
    #expect(repeatedCompletion == SpatialInteractionTransition(
        progress: .completed,
        didAdvance: false
    ))
}

@Test func hoverStepRequiresTheConfiguredDwellAndRejectsClicks() throws {
    let step = try SpatialInteractionStep(
        identifier: "show-tooltip",
        displayIdentifier: 7,
        region: SpatialInteractionRect(x: 100, y: 200, width: 80, height: 40),
        screenshotWidth: 1_000,
        screenshotHeight: 500,
        kind: .hover(minimumDuration: 0.65)
    )

    let click = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .click(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220)
        )
    )
    let shortHover = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .hover(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220),
            duration: 0.64
        )
    )
    let completedHover = SpatialInteractionReducer.reduce(
        progress: .waiting,
        step: step,
        event: .hover(
            displayIdentifier: 7,
            screenshotPoint: SpatialInteractionPoint(x: 120, y: 220),
            duration: 0.65
        )
    )

    #expect(!click.didAdvance)
    #expect(!shortHover.didAdvance)
    #expect(completedHover == SpatialInteractionTransition(
        progress: .completed,
        didAdvance: true
    ))
}

@Test func interactionTagParserReturnsTheFirstValidTargetAndRemovesAllKnownTags() {
    let result = SpatialInteractionTagParser.parse(
        "Open this menu. "
            + "[TARGET:100,200,80,40:source:control:screen2] "
            + "[HOVER:10,20,30,40:ignored:screen1]"
    )

    #expect(result.spokenText == "Open this menu.")
    #expect(result.step == SpatialInteractionStepDescriptor(
        screenNumber: 2,
        region: SpatialInteractionRect(
            x: 100,
            y: 200,
            width: 80,
            height: 40
        ),
        label: "source:control",
        kind: .target
    ))
}

@Test func interactionTagParserUsesTheFixedHoverDwellDuration() {
    let result = SpatialInteractionTagParser.parse(
        "Pause here. [hover:0,0,120,60:tooltip:screen1]"
    )

    #expect(result.spokenText == "Pause here.")
    #expect(result.step == SpatialInteractionStepDescriptor(
        screenNumber: 1,
        region: SpatialInteractionRect(
            x: 0,
            y: 0,
            width: 120,
            height: 60
        ),
        label: "tooltip",
        kind: .hover(minimumDuration: 0.65)
    ))
}

@Test func interactionTagParserSkipsMalformedTagsAndDoesNotSpeakThem() {
    let result = SpatialInteractionTagParser.parse(
        "Try this. "
            + "[TARGET:0,0,0,40:no width:screen1] "
            + "[HOVER:-1,0,20,20:negative origin:screen1] "
            + "[TARGET:10,20,30,40:valid:screen3] "
            + "[CLICK:1,2,3,4:unknown:screen1]"
    )

    #expect(result.spokenText == "Try this.    [CLICK:1,2,3,4:unknown:screen1]")
    #expect(result.step == SpatialInteractionStepDescriptor(
        screenNumber: 3,
        region: SpatialInteractionRect(
            x: 10,
            y: 20,
            width: 30,
            height: 40
        ),
        label: "valid",
        kind: .target
    ))
}

@Test func interactionTagParserRejectsMissingOrInvalidScreenSuffixes() {
    let result = SpatialInteractionTagParser.parse(
        "No step. "
            + "[TARGET:10,20,30,40:missing] "
            + "[TARGET:10,20,30,40:bad:screen0] "
            + "[HOVER:10,20,30,40:bad:screenfoo]"
    )

    #expect(result.spokenText == "No step.")
    #expect(result.step == nil)
}

@Test func interactionTagParserBoundsLabelsAndTheNumberOfParsedTags() throws {
    let longLabel = String(repeating: "a", count: 150)
    let boundedLabelResult = SpatialInteractionTagParser.parse(
        "[TARGET:1,2,3,4:\(longLabel):screen1]"
    )
    let boundedStep = try #require(boundedLabelResult.step)

    #expect(
        boundedStep.label.count
            == SpatialInteractionTagParser.maximumLabelCharacterCount
    )

    let malformedTags = (1...SpatialInteractionTagParser.maximumInteractiveTagCount)
        .map { _ in "[TARGET:1,2,0,4:invalid:screen1]" }
        .joined(separator: " ")
    let resultPastTagLimit = SpatialInteractionTagParser.parse(
        malformedTags + " [TARGET:1,2,3,4:past limit:screen1]"
    )

    #expect(resultPastTagLimit.spokenText.isEmpty)
    #expect(resultPastTagLimit.step == nil)
}

@Test func interactionStepRejectsRegionsOutsideTheScreenshot() {
    #expect(throws: SpatialInteractionProtocolError.self) {
        try SpatialInteractionStep(
            identifier: "unsafe",
            displayIdentifier: 7,
            region: SpatialInteractionRect(
                x: 950,
                y: 200,
                width: 100,
                height: 40
            ),
            screenshotWidth: 1_000,
            screenshotHeight: 500,
            kind: .target
        )
    }
}
