import XCTest
@testable import ClickyDictationCore

final class SpatialAnnotationGrammarTests: XCTestCase {
    func testParsesLegacyPointAndRemovesNoneTag() {
        XCTAssertEqual(
            SpatialAnnotationParser.parse(
                "Open this menu. [POINT:120,240:source control:screen2]"
            ),
            SpatialAnnotationParseResult(
                spokenText: "Open this menu.",
                annotations: [
                    SpatialAnnotation(
                        sequenceNumber: 1,
                        screenNumber: 2,
                        label: "source control",
                        kind: .point(SpatialAnnotationPoint(x: 120, y: 240))
                    )
                ]
            )
        )
        XCTAssertEqual(
            SpatialAnnotationParser.parse("No visual needed. [POINT:none]"),
            SpatialAnnotationParseResult(
                spokenText: "No visual needed.",
                annotations: []
            )
        )
    }

    func testParsesEveryStaticShapeInAppearanceOrder() {
        let result = SpatialAnnotationParser.parse(
            "Watch these areas.\n"
                + "[HIGHLIGHT:10,20,200,80:toolbar:screen1]\n"
                + "[SHAPE:line:0,0;100,100:diagonal:screen1]\n"
                + "[SHAPE:arrow:10,30;90,30:next step:screen1]\n"
                + "[SHAPE:circle:25,35;75,85:right angle:screen1]\n"
                + "[SHAPE:curve:0,50;50,0;100,50:arc:screen1]\n"
                + "[SHAPE:polygon:0,0;50,0;50,50;0,50:area:screen1]"
        )

        XCTAssertEqual(result.spokenText, "Watch these areas.")
        XCTAssertEqual(result.annotations.count, 6)
        XCTAssertEqual(result.annotations.map(\.sequenceNumber), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(
            result.annotations.last?.kind,
            .polygon(
                points: [
                    SpatialAnnotationPoint(x: 0, y: 0),
                    SpatialAnnotationPoint(x: 50, y: 0),
                    SpatialAnnotationPoint(x: 50, y: 50),
                    SpatialAnnotationPoint(x: 0, y: 50)
                ]
            )
        )
    }

    func testMalformedKnownTagsAreNotSpokenOrRendered() {
        let result = SpatialAnnotationParser.parse(
            "Explain this. [SHAPE:polygon:0,0;10,10:too few] "
                + "[HIGHLIGHT:0,0,-20,10:negative] "
                + "[SHAPE:unknown:0,0;1,1:nope]"
        )

        XCTAssertEqual(result.spokenText, "Explain this.")
        XCTAssertTrue(result.annotations.isEmpty)
    }

    func testRejectsInvalidScreenAndBoundsAnnotationCount() {
        let invalidScreen = SpatialAnnotationParser.parse(
            "Look. [POINT:10,20:item:screen99]"
        )
        XCTAssertTrue(invalidScreen.annotations.isEmpty)
        XCTAssertTrue(
            SpatialAnnotationParser.parse(
                "Look. [POINT:10,20:item:screenfoo]"
            ).annotations.isEmpty
        )

        let tags = (1...20).map {
            "[POINT:\($0),\($0):item \($0):screen1]"
        }.joined(separator: " ")
        XCTAssertEqual(
            SpatialAnnotationParser.parse(tags).annotations.count,
            SpatialAnnotationParser.maximumAnnotationCount
        )
    }

    func testMapsScreenshotCoordinatesToDisplayPointsAndRejectsOutsideEdges() throws {
        let geometry = SpatialAnnotationDisplayGeometry(
            screenshotWidth: 1000,
            screenshotHeight: 500,
            displayWidth: 500,
            displayHeight: 400
        )

        XCTAssertEqual(
            geometry.displayPoint(
                for: SpatialAnnotationPoint(x: 250, y: 125)
            ),
            SpatialAnnotationPoint(x: 125, y: 100)
        )
        XCTAssertNil(
            geometry.displayPoint(
                for: SpatialAnnotationPoint(x: -20, y: 900)
            )
        )
        XCTAssertEqual(geometry.displayWidth(for: 200), 100)
        XCTAssertEqual(geometry.displayHeight(for: 100), 80)
    }

    func testInvalidGeometryCannotMapCoordinates() {
        let geometry = SpatialAnnotationDisplayGeometry(
            screenshotWidth: 0,
            screenshotHeight: 500,
            displayWidth: 500,
            displayHeight: 400
        )

        XCTAssertNil(
            geometry.displayPoint(for: SpatialAnnotationPoint(x: 1, y: 1))
        )
        XCTAssertNil(geometry.displayWidth(for: 20))
    }

    func testScreenResolverFailsClosedForUnavailableExplicitScreen() {
        XCTAssertNil(
            SpatialAnnotationScreenResolver.resolvedScreenNumber(
                requestedScreenNumber: 2,
                availableScreenNumbers: [1, 3],
                cursorScreenNumber: 1
            )
        )
        XCTAssertEqual(
            SpatialAnnotationScreenResolver.resolvedScreenNumber(
                requestedScreenNumber: nil,
                availableScreenNumbers: [1, 3],
                cursorScreenNumber: 1
            ),
            1
        )
    }
}
