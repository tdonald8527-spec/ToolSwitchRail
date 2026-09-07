import AppKit
import ApplicationServices

/// Keeps expensive background native windows out of the live drag/resize hot path.
///
/// WindowManager still owns canonical geometry and final stack reconciliation. This
/// coordinator only reacts to a drag that starts while the currently selected managed
/// tool is frontmost. It temporarily hides already-visible native managed apps
/// (processes stay alive/warm), places their matching stack windows at the final frame
/// while hidden, then unhides them after the drag settles.
@MainActor
final class DragIsolationCoordinator {
    private struct HiddenAppState {
        let app: NSRunningApplication
        let windows: [AXUIElement]
    }

    private unowned let configStore: ConfigStore
    private unowned let windowManager: WindowManager

    private var eventMonitors: [Any] = []
    private var dragStartFrame: CGRect?
    private var activePIDAtMouseDown: pid_t?
    private var isolationActive = false
    private var hiddenApps: [HiddenAppState] = []
    private var restoreGeneration: UInt = 0

    init(configStore: ConfigStore, windowManager: WindowManager) {
        self.configStore = configStore
        self.windowManager = windowManager
        installEventMonitors()
    }

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }) {
            eventMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            restoreGeneration &+= 1
            dragStartFrame = windowManager.activeContentFrame
            activePIDAtMouseDown = NSWorkspace.shared.frontmostApplication?.processIdentifier

        case .leftMouseDragged:
            guard !windowManager.isMinimized,
                  let start = dragStartFrame,
                  let activePID = activePIDAtMouseDown,
                  activePIDBelongsToSelectedWorkspace(activePID) else {
                return
            }

            // Isolate from the first real drag event instead of waiting until the
            // canonical frame has already moved by 1pt. The previous one-frame delay
            // was enough to expose a sliver of the warm stack at the old position.
            if !isolationActive {
                beginIsolation(stackFrame: start, activePID: activePID)
            }

        case .leftMouseUp:
            let finalFrame = windowManager.activeContentFrame ?? dragStartFrame
            if isolationActive, let finalFrame {
                finishIsolation(finalFrame: finalFrame)
            } else {
                resetGestureState()
            }

        default:
            break
        }
    }

    private func activePIDBelongsToSelectedWorkspace(_ pid: pid_t) -> Bool {
        guard let tool = windowManager.activeTool else { return false }

        switch tool.kind {
        case .app:
            return runningApplications(for: tool).contains(where: { $0.processIdentifier == pid })
        case .web:
            return browserApplications().contains(where: { $0.processIdentifier == pid })
        }
    }

    private func beginIsolation(stackFrame: CGRect, activePID: pid_t?) {
        guard !isolationActive else { return }
        isolationActive = true
        hiddenApps.removeAll()

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

                let windows = stackWindows(for: app, near: stackFrame)
                guard !windows.isEmpty else { continue }

                hiddenApps.append(HiddenAppState(app: app, windows: windows))
                app.hide()
            }
        }
    }

    private func finishIsolation(finalFrame: CGRect) {
        restoreGeneration &+= 1
        let generation = restoreGeneration
        let states = hiddenApps
        hiddenApps.removeAll()
        isolationActive = false

        let final = rounded(finalFrame)

        // Place while hidden first. When the apps return they should already sit under
        // the foreground window at the new canonical slot.
        for state in states {
            guard !state.app.isTerminated else { continue }
            for window in state.windows {
                setFrame(window, nsFrame: final)
            }
        }

        for state in states where !state.app.isTerminated {
            state.app.unhide()
        }

        // Electron apps do not all restore on the same cadence. A single 60ms write
        // was not enough: some apps restore a cached frame later and expose a strip of
        // the old window above/beside the foreground member. Reassert at three settle
        // points without putting siblings back into the live drag hot path.
        for delay: UInt64 in [60_000_000, 180_000_000, 420_000_000] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, generation == self.restoreGeneration else { return }
                for state in states where !state.app.isTerminated && !state.app.isHidden {
                    for window in state.windows {
                        guard !self.boolAttribute(window, kAXMinimizedAttribute as CFString) else { continue }
                        if let current = self.windowFrame(window), self.framesClose(current, final, tolerance: 0.5) {
                            continue
                        }
                        self.setFrame(window, nsFrame: final)
                    }
                }
            }
        }

        resetGestureState(keepRestoreGeneration: true)
    }

    private func resetGestureState(keepRestoreGeneration: Bool = false) {
        if !keepRestoreGeneration {
            restoreGeneration &+= 1
        }
        dragStartFrame = nil
        activePIDAtMouseDown = nil
        if !isolationActive {
            hiddenApps.removeAll()
        }
    }

    private func runningApplications(for tool: ToolItem) -> [NSRunningApplication] {
        let workspace = NSWorkspace.shared
        var apps: [NSRunningApplication] = []

        if let bundleID = tool.bundleIdentifier, !bundleID.isEmpty {
            apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
        }

        let aliases = alternativeBundleIdentifiers(for: tool)
        for bundleID in aliases where !apps.contains(where: { $0.bundleIdentifier == bundleID }) {
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

    private func browserApplications() -> [NSRunningApplication] {
        let browser = configStore.configuration.browser
        var apps: [NSRunningApplication] = []

        if let bundleID = browser.bundleIdentifier, !bundleID.isEmpty {
            apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
        }

        if apps.isEmpty {
            apps.append(contentsOf: NSWorkspace.shared.runningApplications.filter {
                $0.localizedName?.localizedCaseInsensitiveCompare(browser.appName) == .orderedSame
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

    private func stackWindows(for app: NSRunningApplication, near frame: CGRect) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let windows = rawValue as? [AXUIElement] else {
            return []
        }

        return windows.filter { window in
            let role = stringAttribute(window, kAXRoleAttribute as CFString)
            guard role == "AXWindow" else { return false }

            let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
            if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" { return false }
            if boolAttribute(window, kAXMinimizedAttribute as CFString) { return false }

            guard let current = windowFrame(window) else { return false }
            return framesClose(current, frame, tolerance: 8)
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

        if let position = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let dimensions = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
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
