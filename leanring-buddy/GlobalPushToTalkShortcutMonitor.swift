//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

enum SpatialInteractionObservedPointerEvent {
    case pointerMoved(SpatialCursorSample)
    case leftMouseUp(SpatialCursorSample)
}

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutEventPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutEvent, Never>()
    let spatialCursorSamplePublisher = PassthroughSubject<SpatialCursorSample, Never>()
    let spatialInteractionEventPublisher =
        PassthroughSubject<SpatialInteractionObservedPointerEvent, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    private var activeShortcutKind: BuddyPushToTalkShortcut.ShortcutKind?
    private var isWaitingForNeutralModifierState = false
    private var lastPublishedSpatialCursorTimestamp: TimeInterval?
    private var isSpatialInteractionObservationEnabled = false

    private let minimumSpatialCursorSampleInterval: TimeInterval = 1.0 / 30.0

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .mouseMoved,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        activeShortcutKind = nil
        isWaitingForNeutralModifierState = false
        lastPublishedSpatialCursorTimestamp = nil
        isSpatialInteractionObservationEnabled = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    func setSpatialInteractionObservationEnabled(_ enabled: Bool) {
        guard isSpatialInteractionObservationEnabled != enabled else { return }
        isSpatialInteractionObservationEnabled = enabled
        if enabled {
            lastPublishedSpatialCursorTimestamp = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if Self.isPointerMovementEvent(eventType) {
            let companionShortcutIsActive: Bool
            if case .some(.companion) = activeShortcutKind {
                companionShortcutIsActive = true
            } else {
                companionShortcutIsActive = false
            }
            guard companionShortcutIsActive
                    || isSpatialInteractionObservationEnabled else {
                return Unmanaged.passUnretained(event)
            }
            guard let spatialCursorSample = spatialCursorSample(
                from: event,
                force: false
            ) else {
                return Unmanaged.passUnretained(event)
            }
            if companionShortcutIsActive {
                spatialCursorSamplePublisher.send(spatialCursorSample)
            }
            if isSpatialInteractionObservationEnabled {
                spatialInteractionEventPublisher.send(
                    .pointerMoved(spatialCursorSample)
                )
            }
            return Unmanaged.passUnretained(event)
        }

        if eventType == .leftMouseUp {
            guard isSpatialInteractionObservationEnabled,
                  let spatialCursorSample = spatialCursorSample(
                      from: event,
                      force: true
                  ) else {
                return Unmanaged.passUnretained(event)
            }
            spatialInteractionEventPublisher.send(
                .leftMouseUp(spatialCursorSample)
            )
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let activeShortcutKind {
            let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
                for: eventType,
                keyCode: eventKeyCode,
                modifierFlagsRawValue: event.flags.rawValue,
                shortcutOption: activeShortcutKind.shortcutOption,
                wasShortcutPreviouslyPressed: true
            )

            if shortcutTransition == .released {
                if case .companion = activeShortcutKind {
                    publishSpatialCursorSample(from: event, force: true)
                }
                self.activeShortcutKind = nil
                isShortcutCurrentlyPressed = false
                isWaitingForNeutralModifierState = !BuddyPushToTalkShortcut
                    .hasNoShortcutModifierFlags(event.flags.rawValue)
                shortcutEventPublisher.send(BuddyPushToTalkShortcut.ShortcutEvent(
                    kind: activeShortcutKind,
                    transition: .released
                ))
            }

            return Unmanaged.passUnretained(event)
        }

        if isWaitingForNeutralModifierState {
            if BuddyPushToTalkShortcut.hasNoShortcutModifierFlags(event.flags.rawValue) {
                isWaitingForNeutralModifierState = false
            }
            return Unmanaged.passUnretained(event)
        }

        let newlyPressedShortcutKind = BuddyPushToTalkShortcut.ShortcutKind.allCases
            .first { shortcutKind in
                BuddyPushToTalkShortcut.shortcutTransition(
                    for: eventType,
                    keyCode: eventKeyCode,
                    modifierFlagsRawValue: event.flags.rawValue,
                    shortcutOption: shortcutKind.shortcutOption,
                    wasShortcutPreviouslyPressed: false
                ) == .pressed
            }

        if let newlyPressedShortcutKind {
            isSpatialInteractionObservationEnabled = false
            activeShortcutKind = newlyPressedShortcutKind
            isShortcutCurrentlyPressed = true
            shortcutEventPublisher.send(BuddyPushToTalkShortcut.ShortcutEvent(
                kind: newlyPressedShortcutKind,
                transition: .pressed
            ))
            if case .companion = newlyPressedShortcutKind {
                publishSpatialCursorSample(from: event, force: true)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func publishSpatialCursorSample(
        from event: CGEvent,
        force: Bool
    ) {
        guard let spatialCursorSample = spatialCursorSample(
            from: event,
            force: force
        ) else {
            return
        }
        spatialCursorSamplePublisher.send(spatialCursorSample)
    }

    private func spatialCursorSample(
        from event: CGEvent,
        force: Bool
    ) -> SpatialCursorSample? {
        let sampleTimestamp = TimeInterval(event.timestamp) / 1_000_000_000
        if !force,
           let lastPublishedSpatialCursorTimestamp,
           sampleTimestamp - lastPublishedSpatialCursorTimestamp
                < minimumSpatialCursorSampleInterval {
            return nil
        }

        let globalPoint = event.location
        var displayIdentifier: CGDirectDisplayID = 0
        var matchingDisplayCount: UInt32 = 0
        let displayLookupResult = CGGetDisplaysWithPoint(
            globalPoint,
            1,
            &displayIdentifier,
            &matchingDisplayCount
        )
        guard displayLookupResult == .success, matchingDisplayCount == 1 else {
            return nil
        }

        let sample = SpatialCursorSample(
            displayIdentifier: displayIdentifier,
            globalPoint: SpatialInteractionPoint(
                x: globalPoint.x,
                y: globalPoint.y
            ),
            timestamp: sampleTimestamp
        )

        lastPublishedSpatialCursorTimestamp = sampleTimestamp
        return sample
    }

    private static func isPointerMovementEvent(
        _ eventType: CGEventType
    ) -> Bool {
        switch eventType {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
