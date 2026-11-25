import AppKit
import ApplicationServices

/// Enforces the core workspace geometry invariant:
///
///     rail.maxX == managedWindow.minX
///
/// It also performs a final integrity pass for already-visible native stack members so
/// a background Electron app cannot restore an old cached frame and peek out above or
/// beside the foreground tool. Hidden/minimized siblings are never woken by this pass.
@MainActor
final class RailAdjacencyCoordinator {
    private unowned let configStore: ConfigStore
    private unowned let windowManager: WindowManager
    private weak var railWindowController: RailWindowController?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var enforcementGeneration: UInt = 0
    private var mouseDownGeometry: (windowID: CGWindowID, frame: CGRect)?
    private var mouseDownPID: pid_t?

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

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        let handleEvent: (NSEvent) -> Void = { [weak self] event in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleMouseEvent(event) }
            } else {
                DispatchQueue.main.async { self?.handleMouseEvent(event) }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handleEvent) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handleEvent(event)
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            enforcementGeneration &+= 1 // A new interaction supersedes old settle checks.
            mouseDownGeometry = windowManager.currentTargetGeometry()
            mouseDownPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        case .leftMouseUp:
            defer { mouseDownGeometry = nil; mouseDownPID = nil }
            guard !windowManager.isMinimized,
                  let startPID = mouseDownPID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == startPID,
                  let start = mouseDownGeometry,
                  let current = windowManager.currentTargetGeometry(),
                  start.windowID == current.windowID,
                  !framesClose(start.frame, current.frame, tolerance: 0.5) else { return }
            scheduleEnforcement()
        default:
            break
        }
    }

    private func scheduleEnforcement() {
        enforcementGeneration &+= 1
        let generation = enforcementGeneration

        // The later checks catch Electron apps that finish their own restore/zoom
        // animation after the foreground tool has already settled.
        for delay: UInt64 in [0, 80_000_000, 220_000_000, 500_000_000] {
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

        let canonical: CGRect
        if actualFrame.minX >= minimumTargetX - 0.5 {
            canonical = rounded(actualFrame)
        } else {
            // The app entered the rail's reserved strip. Move it right and, if needed,
            // trim only the right edge so the complete workspace remains on-screen.
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

            canonical = rounded(corrected)
            setFrame(targetWindow, nsFrame: canonical)
        }

        windowManager.activeContentFrame = canonical
        railWindowController?.move(to: CGRect(
            x: canonical.minX - railWidth,
            y: canonical.minY,
            width: railWidth,
            height: canonical.height
        ))

        // Warm stack invariant: every already-visible native sibling must end with the
        // same exact frame as the current foreground window. Never unhide or deminimize.
        reconcileVisibleNativeSiblings(
            to: canonical,
            excludingPID: frontApp.processIdentifier,
            targetWindowID: targetWindowID
        )
    }

    private func reconcileVisibleNativeSiblings(
        to canonical: CGRect,
        excludingPID activePID: pid_t,
        targetWindowID: CGWindowID
    ) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var seenPIDs = Set<pid_t>()

        for tool in configStore.configuration.tools where tool.enabled && tool.kind == .app {
            for app in runningApplications(for: tool) {
                let pid = app.processIdentifier
                if pid == selfPID || pid == activePID { continue }
                if !seenPIDs.insert(pid).inserted { continue }
                if app.isTerminated || app.isHidden { continue }

                let appName = (app.localizedName ?? "").lowercased()
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                if appName.contains("rustdesk") || bundleID.contains("rustdesk") { continue }
                if isConfiguredBrowser(app) { continue }

                guard let window = preferredVisibleWindow(for: app) else { continue }
                if let wid = WindowManager.windowID(for: window), wid == targetWindowID { continue }
                if boolAttribute(window, kAXMinimizedAttribute as CFString) { continue }

                if let current = windowFrame(window), framesClose(current, canonical, tolerance: 0.5) {
                    continue
                }
                setFrame(window, nsFrame: canonical)
            }
        }
    }

    private func runningApplications(for tool: ToolItem) -> [NSRunningApplication] {
        let workspace = NSWorkspace.shared
        var apps: [NSRunningApplication] = []

        if let bundleID = tool.bundleIdentifier, !bundleID.isEmpty {
            apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
        }

        for bundleID in alternativeBundleIdentifiers(for: tool)
        where !apps.contains(where: { $0.bundleIdentifier == bundleID }) {
            apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
        }

        if apps.isEmpty {
            let candidates = [tool.appName, tool.name, tool.id]
                .compactMap { $0?.lowercased() }
                .filter { !$0.isEmpty }
            apps.append(contentsOf: workspace.runningApplications.filter { app in
                guard let name = app.localizedName?.lowercased() else { return false }
                return candidates.contains(where: { name == $0 || name.contains($0) || $0.contains(name) })
            })
        }

        var seen = Set<pid_t>()
        return apps.filter { seen.insert($0.processIdentifier).inserted }
    }

    private func alternativeBundleIdentifiers(for tool: ToolItem) -> [String] {
        switch tool.id.lowercased() {
        case "codex", "chatgpt", "chatgpt-app", "chatgpt-mac":
            return ["com.openai.codex", "com.openai.chat"]
        case "workbuddy":
            return ["com.tencent.workbuddy.mac"]
        case "hermes":
            return ["com.nousresearch.hermes"]
        case "antigravity":
            return ["com.google.antigravity", "com.google.antigravity-ide"]
        case "grok-bot", "grokbot":
            return ["com.anysphere.sand"]
        case "wps-lingxi", "wpslingxi", "lingxi":
            return ["com.wps.lingxi", "com.kingsoft.wpsoffice.lingxi"]
        default:
            return []
        }
    }

    private func isConfiguredBrowser(_ app: NSRunningApplication) -> Bool {
        let browser = configStore.configuration.browser
        if let bundleID = browser.bundleIdentifier, !bundleID.isEmpty,
           app.bundleIdentifier == bundleID {
            return true
        }
        return app.localizedName?.localizedCaseInsensitiveCompare(browser.appName) == .orderedSame
    }

    private func preferredVisibleWindow(for app: NSRunningApplication) -> AXUIElement? {
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

        let candidates = windows.filter { window in
            let role = stringAttribute(window, kAXRoleAttribute as CFString)
            guard role == "AXWindow" else { return false }

            let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
            if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" { return false }
            if boolAttribute(window, kAXMinimizedAttribute as CFString) { return false }
            guard let frame = windowFrame(window) else { return false }
            return frame.width >= 100 && frame.height >= 100
        }

        if let main = candidates.first(where: { boolAttribute($0, kAXMainAttribute as CFString) }) {
            return main
        }
        return candidates.first
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

    private func rounded(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    private func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance &&
        abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance &&
        abs(a.height - b.height) <= tolerance
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

        // Resize first, then position. This is safer for apps restoring a cached frame
        // because the final position is the last AX write and therefore wins visually.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let pointValue = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
