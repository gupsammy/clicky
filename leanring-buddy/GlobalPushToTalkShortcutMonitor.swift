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

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutEventPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutEvent, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    private var activeShortcutKind: BuddyPushToTalkShortcut.ShortcutKind?
    private var isWaitingForNeutralModifierState = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
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

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
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
            activeShortcutKind = newlyPressedShortcutKind
            isShortcutCurrentlyPressed = true
            shortcutEventPublisher.send(BuddyPushToTalkShortcut.ShortcutEvent(
                kind: newlyPressedShortcutKind,
                transition: .pressed
            ))
        }

        return Unmanaged.passUnretained(event)
    }
}
