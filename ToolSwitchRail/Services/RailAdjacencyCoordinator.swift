import AppKit
import ApplicationServices

/// Enforces the core workspace geometry invariant:
///
///     rail.maxX == managedWindow.minX
///
/// Some third-party apps (especially Electron apps) can move/zoom themselves back to
/// the screen's left edge after Tool Switch Rail has already placed them. When that
/// happens the rail would otherwise overlap the app's own sidebar and traffic lights.
/// This coordinator re-checks the exact tracked window after activation and mouse-up,
/// then repairs only that window if it crosses into the rail's reserved strip.
@MainActor
final class RailAdjacencyCoordinator {
    private unowned let configStore: ConfigStore
    private unowned let windowManager: WindowManager
    private weak var railWindowController: RailWindowController?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var enforcementGeneration: UInt = 0

    init(
        configStore: ConfigStore,
        windowManager: WindowManager,
        railWindowController: RailWindowController
    ) {
        self.configStore = configStore
        self.windowManager = windowManager
        self.railWindowController = railWindowController
        installObservers()
        scheduleEnforcement()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let activation = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleEnforcement()
            }
        }
        workspaceObservers.append(activation)

        let mask: NSEvent.EventTypeMask = [.leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleEnforcement()
            }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.scheduleEnforcement()
            }
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func scheduleEnforcement() {
        enforcementGeneration &+= 1
        let generation = enforcementGeneration

        // First check catches ordinary drags/activations. Follow-up checks catch apps
        // that finish their own zoom/restore animation slightly later and overwrite AX.
        for delay: UInt64 in [0, 80_000_000, 220_000_000] {
            Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard let self, generation == self.enforcementGeneration else { return }
                self.enforceAdjacencyIfNeeded()
            }
        }
    }

    private func enforceAdjacencyIfNeeded() {
        guard !windowManager.isMinimized,
              let targetWindowID = windowManager.currentTargetWindowID,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              !frontApp.isTerminated,
              let targetWindow = trackedWindow(in: frontApp, windowID: targetWindowID),
              !boolAttribute(targetWindow, kAXMinimizedAttribute as CFString),
              let actualFrame = windowFrame(targetWindow) else {
            return
        }

        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        guard railWidth > 0 else { return }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(actualFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let minimumTargetX = visible.minX + railWidth

        // Normal case: keep the rail exactly adjacent if its own origin drifted.
        if actualFrame.minX >= minimumTargetX - 0.5 {
            let expectedRail = CGRect(
                x: actualFrame.minX - railWidth,
                y: actualFrame.minY,
                width: railWidth,
                height: actualFrame.height
            )
            railWindowController?.move(to: expectedRail)
            windowManager.activeContentFrame = actualFrame
            return
        }

        // The app has entered the rail's reserved strip. Move it right. If the app was
        // zoomed to screen width, reduce only the right-side width needed to keep the
        // complete workspace on-screen instead of covering the app with the rail.
        var corrected = actualFrame
        corrected.origin.x = minimumTargetX
        corrected.size.width = min(corrected.width, visible.maxX - minimumTargetX)
        corrected.size.height = min(corrected.height, visible.height)

        if corrected.maxY > visible.maxY {
            corrected.origin.y = visible.maxY - corrected.height
        }
        if corrected.minY < visible.minY {
            corrected.origin.y = visible.minY
        }

        corrected = CGRect(
            x: corrected.minX.rounded(),
            y: corrected.minY.rounded(),
            width: corrected.width.rounded(),
            height: corrected.height.rounded()
        )

        setFrame(targetWindow, nsFrame: corrected)
        windowManager.activeContentFrame = corrected

        railWindowController?.move(to: CGRect(
            x: corrected.minX - railWidth,
            y: corrected.minY,
            width: railWidth,
            height: corrected.height
        ))
    }

    private func trackedWindow(in app: NSRunningApplication, windowID: CGWindowID) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success,
        let windows = rawValue as? [AXUIElement] else {
            return nil
        }

        return windows.first { window in
            guard let candidateID = WindowManager.windowID(for: window) else { return false }
            return candidateID == windowID
        }
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posAX = posValue,
              let sizeAX = sizeValue,
              CFGetTypeID(posAX) == AXValueGetTypeID(),
              CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posAX as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        guard size.width > 50, size.height > 50 else { return nil }

        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 1080
        return CGRect(
            x: point.x,
            y: primaryHeight - point.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func setFrame(_ window: AXUIElement, nsFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 1080

        var point = CGPoint(x: nsFrame.minX, y: primaryHeight - nsFrame.maxY)
        var size = CGSize(width: nsFrame.width, height: nsFrame.height)

        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let pointValue = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        }
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
