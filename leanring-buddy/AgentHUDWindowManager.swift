//
//  AgentHUDWindowManager.swift
//  leanring-buddy
//
//  Owns the top-center agent notch and interactive screen-local token rails.
//

import AppKit
import Combine
import SwiftUI

private final class AgentHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentHUDWindowManager {
    private let presentationModel: AgentPresentationModel

    private var notchPanel: AgentHUDPanel?
    private var tokenPanelsByDisplayIdentifier: [CGDirectDisplayID: AgentHUDPanel] = [:]
    private var modelObservation: AnyCancellable?
    private var screenChangeObserver: NSObjectProtocol?
    private var activeSpaceChangeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    init(presentationModel: AgentPresentationModel) {
        self.presentationModel = presentationModel

        modelObservation = Publishers.Merge(
            presentationModel.$isNotchExpanded.map { _ in () },
            presentationModel.$tokenLayoutRevision.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshWindowLayout()
            }
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildAllWindows()
            }
        }

        activeSpaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildAllWindows()
            }
        }
    }

    deinit {
        // Panels are not ordered out here: this manager lives for the app's
        // lifetime and its panels use isReleasedWhenClosed = false, so ARC
        // teardown suffices. If this manager ever becomes shorter-lived, call
        // hide() before releasing it so no orphaned panels stay on screen.
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if let activeSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                activeSpaceChangeObserver
            )
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    func show() {
        createNotchPanelIfNeeded()
        refreshWindowLayout()
        installOutsideClickMonitor()
    }

    func hide() {
        notchPanel?.orderOut(nil)
        notchPanel?.contentView = nil
        notchPanel = nil

        for panel in tokenPanelsByDisplayIdentifier.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        tokenPanelsByDisplayIdentifier.removeAll()
    }

    private func rebuildAllWindows() {
        hide()
        show()
    }

    private func createNotchPanelIfNeeded() {
        guard notchPanel == nil else { return }

        let panel = makePanel()
        panel.contentView = NSHostingView(
            rootView: AgentNotchView(presentationModel: presentationModel)
        )
        notchPanel = panel
    }

    private func refreshWindowLayout() {
        guard let primaryScreen = NSScreen.screens.first else {
            hide()
            return
        }

        createNotchPanelIfNeeded()
        updateNotchPanel(on: primaryScreen)
        reconcileTokenPanels()
    }

    private func updateNotchPanel(on screen: NSScreen) {
        guard let notchPanel else { return }

        let panelSize = presentationModel.isNotchExpanded
            ? expandedNotchSize(for: screen)
            : collapsedNotchSize(for: screen)
        let panelOrigin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height
        )

        let targetFrame = CGRect(origin: panelOrigin, size: panelSize)
        if notchPanel.frame != targetFrame {
            notchPanel.setFrame(
                targetFrame,
                display: true,
                animate: notchPanel.isVisible
            )
        }
        notchPanel.contentView?.frame = CGRect(origin: .zero, size: panelSize)
        notchPanel.orderFrontRegardless()

        if presentationModel.isNotchExpanded {
            notchPanel.makeKeyAndOrderFront(nil)
        } else if notchPanel.isKeyWindow {
            notchPanel.resignKey()
        }
    }

    private func reconcileTokenPanels() {
        let currentScreensByIdentifier = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                AgentPresentationModel.displayIdentifier(for: screen).map { ($0, screen) }
            }
        )
        let identifiersWithTasks = Set(currentScreensByIdentifier.keys.filter { identifier in
            !presentationModel.tasks(for: identifier).isEmpty
        })

        for identifier in Array(tokenPanelsByDisplayIdentifier.keys)
            where !identifiersWithTasks.contains(identifier) {
            tokenPanelsByDisplayIdentifier.removeValue(forKey: identifier)?.orderOut(nil)
        }

        for identifier in identifiersWithTasks {
            guard let screen = currentScreensByIdentifier[identifier] else { continue }
            let panel = tokenPanelsByDisplayIdentifier[identifier] ?? {
                let newPanel = makePanel()
                newPanel.contentView = NSHostingView(
                    rootView: AgentTokenRailView(
                        presentationModel: presentationModel,
                        displayIdentifier: identifier
                    )
                )
                tokenPanelsByDisplayIdentifier[identifier] = newPanel
                return newPanel
            }()

            let taskCount = presentationModel.tasks(for: identifier).count
            let visibleTaskCount = min(taskCount, 4)
            let panelHeight = CGFloat(visibleTaskCount * 54 + (taskCount > 4 ? 32 : 0))
            let panelSize = CGSize(width: 292, height: panelHeight)
            let panelOrigin = CGPoint(
                x: screen.visibleFrame.maxX - panelSize.width - 12,
                y: screen.visibleFrame.maxY - panelSize.height - 10
            )
            panel.setFrame(
                CGRect(origin: panelOrigin, size: panelSize),
                display: true
            )
            panel.contentView?.frame = CGRect(origin: .zero, size: panelSize)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> AgentHUDPanel {
        let panel = AgentHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  self.presentationModel.isNotchExpanded,
                  let notchPanel = self.notchPanel,
                  !notchPanel.frame.contains(NSEvent.mouseLocation) else {
                return
            }
            self.presentationModel.collapseNotch()
        }
    }

    private func collapsedNotchSize(for screen: NSScreen) -> CGSize {
        CGSize(
            width: min(460, max(280, screen.frame.width * 0.30)),
            height: 40
        )
    }

    private func expandedNotchSize(for screen: NSScreen) -> CGSize {
        CGSize(
            width: min(820, screen.visibleFrame.width - 40),
            height: min(520, screen.visibleFrame.height - 48)
        )
    }
}
