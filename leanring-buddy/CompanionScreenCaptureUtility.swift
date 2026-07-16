//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let displayIdentifier: CGDirectDisplayID
    let screenNumber: Int?
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let displayFrameInCoreGraphicsCoordinates: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

struct CompanionScreenCaptureAttachmentSet {
    let imagePaths: [String]
    let promptDescription: String

    private let directoryURL: URL

    init(screenCaptures: [CompanionScreenCapture]) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-screen-captures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            var imagePaths: [String] = []
            var promptLines: [String] = []
            for (captureIndex, screenCapture) in screenCaptures.enumerated() {
                let imageURL = directoryURL
                    .appendingPathComponent("screen-\(captureIndex + 1).jpg")
                try screenCapture.imageData.write(to: imageURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: imageURL.path
                )
                imagePaths.append(imageURL.path)
                promptLines.append(
                    "Image \(captureIndex + 1): \(screenCapture.label) "
                        + "(\(screenCapture.screenshotWidthInPixels)x"
                        + "\(screenCapture.screenshotHeightInPixels) pixels, "
                        + "display ID \(screenCapture.displayIdentifier))"
                )
            }

            self.imagePaths = imagePaths
            self.promptDescription = promptLines.joined(separator: "\n")
            self.directoryURL = directoryURL
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
enum CompanionScreenCaptureUtility {
    private static let minimumMeaningfulSpatialTraceDistance: Double = 12
    private static let minimumSpatialHoverApproachDistance: Double = 4
    private static let minimumMeaningfulSpatialHoverDuration: TimeInterval = 0.65

    static func captureFocusedDisplayAsJPEG(
        focusedElementFrameInCoreGraphicsCoordinates: CGRect
    ) async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let selectedDisplayIndex = ScreenAwareDisplaySelector.displayIndex(
            containing: focusedElementFrameInCoreGraphicsCoordinates,
            displayFrames: content.displays.map(\.frame)
        )
        guard let selectedDisplayIndex else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Clicky could not identify the display containing the focused field."
                ]
            )
        }

        let selectedDisplay = content.displays[selectedDisplayIndex]
        let displayFrame = appKitDisplayFrame(for: selectedDisplay)
        let excludedOwnAppWindows = ownAppWindows(in: content)
        guard let screenCapture = try await captureDisplayAsJPEG(
            selectedDisplay,
            content: content,
            excludingWindows: excludedOwnAppWindows,
            displayFrame: displayFrame,
            label: "display containing the focused text field",
            screenNumber: nil
        ) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture the focused display"]
            )
        }
        return screenCapture
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let excludedOwnAppWindows = ownAppWindows(in: content)

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            if let screenCapture = try await captureDisplayAsJPEG(
                display,
                content: content,
                excludingWindows: excludedOwnAppWindows,
                displayFrame: displayFrame,
                label: screenLabel,
                screenNumber: displayIndex + 1
            ) {
                capturedScreens.append(screenCapture)
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    static func spatialGroundingPromptBlock(
        for spatialCursorTrace: SpatialCursorTrace?,
        screenCaptures: [CompanionScreenCapture]
    ) -> String? {
        guard let spatialCursorTrace,
              spatialCursorTrace.samples.count >= 2,
              let traceDisplayIdentifier = spatialCursorTrace.samples.first?
                .displayIdentifier,
              spatialCursorTrace.samples.allSatisfy({
                  $0.displayIdentifier == traceDisplayIdentifier
              }),
              let matchingCaptureIndex = screenCaptures.firstIndex(where: {
                  $0.displayIdentifier == traceDisplayIdentifier
              }) else {
            return nil
        }

        let matchingCapture = screenCaptures[matchingCaptureIndex]
        let screenshotGeometry = SpatialScreenshotGeometry(
            displayIdentifier: matchingCapture.displayIdentifier,
            globalDisplayFrame: SpatialInteractionRect(
                x: matchingCapture.displayFrameInCoreGraphicsCoordinates.origin.x,
                y: matchingCapture.displayFrameInCoreGraphicsCoordinates.origin.y,
                width: matchingCapture.displayFrameInCoreGraphicsCoordinates.width,
                height: matchingCapture.displayFrameInCoreGraphicsCoordinates.height
            ),
            screenshotWidth: Double(matchingCapture.screenshotWidthInPixels),
            screenshotHeight: Double(matchingCapture.screenshotHeightInPixels),
            globalCoordinateOrigin: .topLeft
        )
        guard let traceSummary = spatialCursorTrace.summary(
            for: screenshotGeometry
        ) else {
            return nil
        }
        let traceDistance = totalDistance(of: spatialCursorTrace.samples)
        let hasMeaningfulTravel = traceDistance
            >= minimumMeaningfulSpatialTraceDistance
        let hasDeliberateHover = traceDistance
            >= minimumSpatialHoverApproachDistance
            && (traceSummary.hover?.duration ?? 0)
                >= minimumMeaningfulSpatialHoverDuration
        guard hasMeaningfulTravel || hasDeliberateHover else {
            return nil
        }

        return """
        <cursor-spatial-grounding>
        The user intentionally moved their pointer to show where this request applies. This is attention context only, not permission to click or act.
        The trace refers to attached Image \(matchingCaptureIndex + 1).
        \(traceSummary.modelDescription)
        </cursor-spatial-grounding>
        """
    }

    private static func ownAppWindows(
        in content: SCShareableContent
    ) -> [SCWindow] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
    }

    private static func appKitDisplayFrame(for display: SCDisplay) -> CGRect {
        for screen in NSScreen.screens {
            let screenDisplayIdentifier = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
            if screenDisplayIdentifier == display.displayID {
                return screen.frame
            }
        }

        return CGRect(
            x: display.frame.origin.x,
            y: display.frame.origin.y,
            width: CGFloat(display.width),
            height: CGFloat(display.height)
        )
    }

    private static func totalDistance(
        of samples: [SpatialCursorSample]
    ) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { distance, samplePair in
            let deltaX = samplePair.1.globalPoint.x
                - samplePair.0.globalPoint.x
            let deltaY = samplePair.1.globalPoint.y
                - samplePair.0.globalPoint.y
            return distance + hypot(deltaX, deltaY)
        }
    }

    private static func captureDisplayAsJPEG(
        _ display: SCDisplay,
        content: SCShareableContent,
        excludingWindows ownAppWindows: [SCWindow],
        displayFrame: CGRect,
        label: String,
        screenNumber: Int?
    ) async throws -> CompanionScreenCapture? {
        let filter = SCContentFilter(
            display: display,
            excludingWindows: ownAppWindows
        )
        let configuration = SCStreamConfiguration()
        let maximumDimension = 1_280
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
        if display.width >= display.height {
            configuration.width = maximumDimension
            configuration.height = Int(CGFloat(maximumDimension) / aspectRatio)
        } else {
            configuration.height = maximumDimension
            configuration.width = Int(CGFloat(maximumDimension) * aspectRatio)
        }

        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let JPEGData = NSBitmapImageRep(cgImage: capturedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return CompanionScreenCapture(
            displayIdentifier: display.displayID,
            screenNumber: screenNumber,
            imageData: JPEGData,
            label: label,
            isCursorScreen: displayFrame.contains(NSEvent.mouseLocation),
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            displayFrameInCoreGraphicsCoordinates: display.frame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}
