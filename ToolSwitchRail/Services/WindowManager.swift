import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class WindowManager: ObservableObject, WindowTrackerDelegate {
    @Published private(set) var selectedToolID: String?
    @Published private(set) var isMinimized: Bool = false
    @Published var lastError: String?
    @Published private(set) var launchingToolID: String?
    @Published private(set) var openToolIDs: Set<String> = []

    var activeTool: ToolItem? {
        guard let id = selectedToolID else { return nil }
        return configStore.configuration.tools.first(where: { $0.id == id })
    }

    private static let _axGetWindowFunc: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = _axGetWindowFunc else { return nil }
        var wid: CGWindowID = 0
        if fn(element, &wid) == .success, wid > 0 {
            return wid
        }
        return nil
    }

    var currentTargetWindowID: CGWindowID? {
        guard let win = windowTracker.currentWindow else { return nil }
        return Self.windowID(for: win)
    }

    // Read actual geometry, not the canonical slot (which can lead or lag a drag).
    // A missing window is unknown; callers must not infer movement from cached data.
    func currentTargetGeometry() -> (windowID: CGWindowID, frame: CGRect)? {
        guard let windowID = currentTargetWindowID,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], windowID) as? [[String: Any]],
              let info = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
              let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber,
              width.doubleValue > 50, height.doubleValue > 50 else { return nil }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 1080
        return (windowID, CGRect(x: x.doubleValue, y: primaryHeight - y.doubleValue - height.doubleValue,
                                width: width.doubleValue, height: height.doubleValue))
    }

    private let configStore: ConfigStore
    private let windowTracker: WindowTracker
    weak var railWindowController: RailWindowController?

    private(set) var canonicalStackFrame: CGRect?
    var activeContentFrame: CGRect? {
        get { canonicalStackFrame }
        set { canonicalStackFrame = newValue }
    }

    private var dragStartRailOrigin: CGPoint?
    private var dragStartAXPoint: CGPoint?
    private var dragStartContentFrame: CGRect?
    private var pendingActivationTask: Task<Void, Never>?
    private var pendingHideTask: Task<Void, Never>?
    private var minimumVerificationTask: Task<Void, Never>?
    private var switchGeneration: UInt = 0
    private var pendingSwitchTask: Task<Void, Never>?
    private var isSwitchingTool = false
    private var ignoreActivationUntil = Date.distantPast
    private var workspaceScanTimer: Timer?
    private var cachedChromeURLs: (timestamp: Date, map: [String: String])?

    // Learned at runtime when a managed window refuses a requested smaller size.
    // This lets the whole stack converge on the strictest minimum among the tools
    // that are actually in use instead of relying only on one hard-coded app size.
    private var learnedMinimumSizes: [String: CGSize] = [:]

    // Live stack synchronization is intentionally throttled. Position-only moves are
    // cheap, while resize calls can cause Electron/Web render work in every sibling.
    private var lastLiveStackSyncTime: TimeInterval = 0
    private var lastLiveStackFrame: CGRect?

    private func activateApp(_ app: NSRunningApplication) {
        if app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return
        }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    func orderAdjacentToTargetWindow(targetWindowID: CGWindowID? = nil) {
        let wid = targetWindowID ?? currentTargetWindowID
        railWindowController?.orderAdjacentToTargetWindow(targetWindowID: wid)
    }

    func prepareForKeyInteraction() {
        railWindowController?.prepareForKeyInteraction()
    }

    func restorePriorFrontmostApp() {
        railWindowController?.restorePriorFrontmostApp()
    }

    /// The single settings menu. Opened from the rail gear, the dashboard gear and a
    /// right-click on the menu-bar icon — same items, same words, everywhere.
    func showSettingsMenu(from point: NSPoint? = nil) {
        prepareForKeyInteraction()
        let menu = buildSettingsMenu()
        let popLocation = point ?? NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: popLocation, in: nil)
        restorePriorFrontmostApp()
    }

    func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Only shown when something is actually wrong.
        if !AccessibilityPermission.isTrusted {
            let axItem = NSMenuItem(title: "⚠︎ 需要辅助功能权限才能对齐窗口…", action: #selector(menuActionCheckAX), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(NSMenuItem.separator())
        }

        let collapseItem = NSMenuItem(
            title: isMinimized ? "显示工作区" : "收起工作区",
            action: #selector(menuActionToggleCollapse),
            keyEquivalent: "m"
        )
        collapseItem.keyEquivalentModifierMask = [.command, .option]
        collapseItem.target = self
        menu.addItem(collapseItem)

        let zoomItem = NSMenuItem(
            title: isMaximized ? "还原窗口大小" : "铺满屏幕",
            action: #selector(menuActionToggleMaximize),
            keyEquivalent: ""
        )
        zoomItem.target = self
        zoomItem.isEnabled = !isMinimized
        menu.addItem(zoomItem)

        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (title, selector) in [
            ("紧凑（960 × 680）", #selector(menuActionPreset1)),
            ("标准（1100 × 750）", #selector(menuActionPreset2)),
            ("宽屏（1400 × 900）", #selector(menuActionPreset3))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            sizeMenu.addItem(item)
        }
        sizeMenu.addItem(NSMenuItem.separator())
        let resetItem = NSMenuItem(title: "恢复默认位置", action: #selector(menuActionResetDefault), keyEquivalent: "")
        resetItem.target = self
        sizeMenu.addItem(resetItem)
        let sizeParent = NSMenuItem(title: "窗口尺寸", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        sizeParent.isEnabled = !isMinimized
        menu.addItem(sizeParent)

        menu.addItem(NSMenuItem.separator())

        let addItem = NSMenuItem(title: "添加应用…", action: #selector(menuActionAddApp), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        let currentTools = configStore.configuration.tools
        if !currentTools.isEmpty {
            let removeMenu = NSMenu()
            for tool in currentTools {
                let item = NSMenuItem(title: tool.name, action: #selector(menuActionRemoveTool(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tool.id
                removeMenu.addItem(item)
            }
            let removeParent = NSMenuItem(title: "从 Rail 移除", action: nil, keyEquivalent: "")
            removeParent.submenu = removeMenu
            menu.addItem(removeParent)
        }

        menu.addItem(NSMenuItem.separator())

        // Option-key alternate: reveal the file instead of opening it.
        let openCfg = NSMenuItem(title: "打开配置文件", action: #selector(menuActionOpenConfig), keyEquivalent: "")
        openCfg.target = self
        menu.addItem(openCfg)
        let revealCfg = NSMenuItem(title: "在访达中显示配置文件", action: #selector(menuActionRevealConfig), keyEquivalent: "")
        revealCfg.target = self
        revealCfg.keyEquivalentModifierMask = [.option]
        revealCfg.isAlternate = true
        menu.addItem(revealCfg)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Tool Switch Rail", action: #selector(menuActionQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuActionToggleCollapse() { toggleMinimize() }
    @objc private func menuActionToggleMaximize() { toggleMaximize() }
    @objc private func menuActionPreset1() { resizeToPreset(width: 1016, height: 680) }
    @objc private func menuActionPreset2() { resizeToPreset(width: 1156, height: 750) }
    @objc private func menuActionPreset3() { resizeToPreset(width: 1456, height: 900) }
    @objc private func menuActionResetDefault() { resetToDefaultGeometry() }
    @objc private func menuActionOpenConfig() { configStore.openConfigFile() }
    @objc private func menuActionRevealConfig() { configStore.revealConfigFile() }
    @objc private func menuActionAddApp() { RailActions.addApp(configStore: configStore, windowManager: self) }
    @objc private func menuActionRemoveTool(_ sender: NSMenuItem) {
        guard let toolID = sender.representedObject as? String else { return }
        RailActions.removeTool(id: toolID, configStore: configStore)
    }
    @objc private func menuActionCheckAX() { RailActions.openAccessibilitySettings() }
    @objc private func menuActionQuit() { NSApp.terminate(nil) }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.windowTracker = WindowTracker(railWidth: CGFloat(configStore.configuration.workspace.railWidth))
        self.windowTracker.delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // A busy Electron app must not freeze the rail: cap every synchronous AX call
        // (the system default is ~6 s) for this process.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let scan = Timer(timeInterval: 3.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanForExternalMinimize()
            }
        }
        RunLoop.main.add(scan, forMode: .common)
        workspaceScanTimer = scan
    }

    var compatibilityMinSize: CGSize {
        let cfgW = CGFloat(configStore.configuration.workspace.minimumWidth)
        let cfgH = CGFloat(configStore.configuration.workspace.minimumHeight)

        var width = cfgW
        var height = cfgH

        // Keep the known WPS floor only when WPS is actually enabled.
        if configStore.configuration.tools.contains(where: {
            $0.enabled && ["wps-lingxi", "wpslingxi", "lingxi"].contains($0.id.lowercased())
        }) {
            width = max(width, 960.0)
            height = max(height, 680.0)
        }

        // Add runtime-learned minimums from every managed tool that resisted a
        // requested resize. The canonical stack can never shrink below the max.
        for size in learnedMinimumSizes.values {
            width = max(width, size.width)
            height = max(height, size.height)
        }

        return CGSize(width: width, height: height)
    }

    func clampToCanonicalConstraints(_ frame: CGRect) -> CGRect {
        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let minAllowedTargetX = visible.minX + railWidth
        let minSize = compatibilityMinSize

        var clamped = frame
        if clamped.width < minSize.width {
            clamped.size.width = minSize.width
        }
        if clamped.height < minSize.height {
            clamped.size.height = minSize.height
        }
        if clamped.maxX > visible.maxX {
            clamped.origin.x = visible.maxX - clamped.size.width
        }
        if clamped.minX < minAllowedTargetX {
            clamped.origin.x = minAllowedTargetX
            clamped.size.width = min(clamped.size.width, visible.maxX - minAllowedTargetX)
        }
        if clamped.size.height > visible.height {
            clamped.size.height = visible.height
        }
        if clamped.maxY > visible.maxY {
            clamped.origin.y = visible.maxY - clamped.size.height
        }
        if clamped.origin.y < visible.minY {
            clamped.origin.y = visible.minY
        }
        return CGRect(
            x: clamped.origin.x.rounded(),
            y: clamped.origin.y.rounded(),
            width: clamped.size.width.rounded(),
            height: clamped.size.height.rounded()
        )
    }

    @objc private func handleAppTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if windowTracker.currentApp?.processIdentifier == pid {
            windowTracker.stopTracking(keepLastFrame: true)
            railWindowController?.show()
            attachToActiveToolIfAvailable()
        }
        refreshOpenTools()
    }

    @objc private func handleSpaceChange(_ notification: Notification) {
        if isMinimized || Date() < ignoreActivationUntil { return }
        if let front = NSWorkspace.shared.frontmostApplication, registeredTool(for: front) != nil {
            _ = attach(to: front)
            windowTracker.checkWindowFrame(force: true)
            orderAdjacentToTargetWindow()
        }
    }

    func attachToActiveToolIfAvailable() {
        guard AccessibilityPermission.isTrusted else { return }
        if isMinimized { return }

        // 1. Try frontmost application
        if let front = NSWorkspace.shared.frontmostApplication,
           attach(to: front) {
            railWindowController?.setFloatingForManagedTool(true)
            return
        }

        // 2. Try any running registered tool with a visible unminimized window.
        // Never wake hidden/minimized sibling tools just to rebuild the stack.
        for tool in configStore.configuration.tools where tool.enabled {
            let apps = runningApplications(for: tool)
            for app in apps {
                if app.isHidden && !isBrowserApplication(app) { continue }
                let windows = standardWindows(for: app, tool: tool)
                if let window = windows.first(where: { !boolAttribute($0, kAXMinimizedAttribute as CFString) }) {
                    if attachToWindow(window, app: app, tool: tool) {
                        let isManagedFront = NSWorkspace.shared.frontmostApplication.flatMap({ registeredTool(for: $0) }) != nil
                        railWindowController?.setFloatingForManagedTool(isManagedFront)
                        return
                    }
                }
            }
        }
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            handleAppActivation(notification)
        }
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        // Workspace notifications can arrive after a newer activation. Only the
        // application that is actually frontmost may change the current intent.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        if isSwitchingTool {
            if let tool = activeTool,
               runningApplications(for: tool).contains(where: { $0.processIdentifier == app.processIdentifier }) {
                return // Activation caused by our current switch; focus already owns it.
            }
            // A Dock/Cmd-Tab/window click takes precedence over a pending launch or
            // settle delay. Do not let the old request take the foreground back.
            cancelPendingSwitchWork()
            ignoreActivationUntil = .distantPast
        } else {
            if Date() < ignoreActivationUntil { return }
            cancelPendingSwitchWork()
        }

        if isMinimized {
            if let tool = registeredTool(for: app) {
                // Dock activation restores only the requested tool. Background siblings
                // remain hidden/minimized until explicitly selected.
                isMinimized = false
                ignoreActivationUntil = Date().addingTimeInterval(0.8)
                railWindowController?.show()
                switchTo(tool)
                return
            }
            if isBrowserApplication(app) {
                ignoreActivationUntil = Date().addingTimeInterval(0.8)
                isMinimized = false
                railWindowController?.show()
                if attach(to: app) {
                    railWindowController?.setFloatingForManagedTool(true)
                    windowTracker.checkWindowFrame(force: true)
                    orderAdjacentToTargetWindow()
                    return
                }
                isMinimized = true
                railWindowController?.hide()
            }
            return
        }

        pendingActivationTask?.cancel()
        pendingActivationTask = nil

        // If the app is already tracked and unminimized, make sure rail is visible and ordered adjacent
        if let currentApp = windowTracker.currentApp,
           currentApp.processIdentifier == app.processIdentifier,
           !isMinimized,
           let curWin = windowTracker.currentWindow,
           !boolAttribute(curWin, kAXMinimizedAttribute as CFString) {
            if isBrowserApplication(app) {
                if attach(to: app) {
                    railWindowController?.setFloatingForManagedTool(true)
                    windowTracker.checkWindowFrame(force: true)
                    orderAdjacentToTargetWindow()
                    return
                }
                railWindowController?.setFloatingForManagedTool(false)
                return
            }
            railWindowController?.setFloatingForManagedTool(true)
            windowTracker.checkWindowFrame(force: true)
            orderAdjacentToTargetWindow()
            return
        }

        if attach(to: app) {
            railWindowController?.setFloatingForManagedTool(true)
            windowTracker.checkWindowFrame(force: true)
            orderAdjacentToTargetWindow()
            return
        }

        let isBrowser = isBrowserApplication(app)
        let toolCandidate = registeredTool(for: app)

        if toolCandidate != nil || (isBrowser && hasZeroVisibleWindows(app)) {
            railWindowController?.setFloatingForManagedTool(true)
            // App is registered (or browser is launching), but its window hasn't appeared yet
            // (e.g. Electron apps take 1-4 seconds on startup, or window unminimize animation in progress).
            // Do NOT hide the rail. Start async polling to attach the moment the window appears.
            pendingActivationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let startTime = Date()
                let timeout: TimeInterval = 15.0
                while Date().timeIntervalSince(startTime) < timeout {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if Task.isCancelled { return }

                    // If user switched to another app, stop waiting
                    if let front = NSWorkspace.shared.frontmostApplication,
                       front.processIdentifier != app.processIdentifier {
                        return
                    }

                    if self.attach(to: app) {
                        self.railWindowController?.setFloatingForManagedTool(true)
                        self.windowTracker.checkWindowFrame(force: true)
                        self.orderAdjacentToTargetWindow()
                        return
                    }
                }

                // Timed out and still no window found while this app is still frontmost.
                // Keep rail visible so user can interact with it and switch to other tools.
            }
        } else {
            railWindowController?.setFloatingForManagedTool(false)
        }
    }

    private func isBrowserApplication(_ app: NSRunningApplication) -> Bool {
        // Chrome and other general browsers must NEVER be managed or attached to the rail.
        // Managed web tools run as dedicated standalone Web Apps (PWAs).
        return false
    }

    /// The general-purpose browser from config (Chrome by default). It can hold many
    /// unrelated windows, so the rail must never hide, move or resize it as a whole.
    /// Chrome/Safari web-app (PWA) processes have their own bundle IDs and are not affected.
    private func isConfiguredBrowser(_ app: NSRunningApplication) -> Bool {
        let browser = configStore.configuration.browser
        if let id = browser.bundleIdentifier, !id.isEmpty,
           app.bundleIdentifier?.caseInsensitiveCompare(id) == .orderedSame {
            return true
        }
        return app.localizedName?.localizedCaseInsensitiveCompare(browser.appName) == .orderedSame
    }

    private func hasZeroVisibleWindows(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
              let axWindows = rawValue as? [AXUIElement] else {
            return true
        }
        return axWindows.isEmpty
    }

    private func registeredTool(for app: NSRunningApplication) -> ToolItem? {
        let appBundleID = app.bundleIdentifier?.lowercased() ?? ""
        let appName = app.localizedName?.lowercased() ?? ""
        let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() ?? ""

        for tool in configStore.configuration.tools where tool.enabled {
            // Check explicit bundleIdentifier
            if let bID = tool.bundleIdentifier?.lowercased(), !bID.isEmpty, appBundleID == bID {
                return tool
            }

            // Check resolved bundleIdentifier
            if let rID = resolvedBundleIdentifier(for: tool)?.lowercased(), !rID.isEmpty, appBundleID == rID {
                return tool
            }

            // Check known alternative bundle identifiers
            for altID in alternativeBundleIdentifiers(for: tool) {
                if appBundleID == altID.lowercased() {
                    return tool
                }
            }

            // Check appName / tool.name / bundleName (exact match first)
            let candidateNames = [tool.appName, tool.name, tool.id].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
            for candidate in candidateNames {
                if appName == candidate || bundleName == candidate {
                    return tool
                }
            }

            // Known tool-specific aliases
            switch tool.id.lowercased() {
            case "wps-lingxi", "wpslingxi", "lingxi":
                if appName.contains("灵犀") || appBundleID.contains("lingxi") || bundleName.contains("灵犀") {
                    return tool
                }
            case "codex", "chatgpt", "chatgpt-app", "chatgpt-mac":
                if tool.kind == .app && (appName == "chatgpt" || appName == "codex" || appBundleID == "com.openai.codex" || appBundleID == "com.openai.chat") {
                    return tool
                }
            case "antigravity":
                if appName.contains("antigravity") || appBundleID.contains("antigravity") {
                    return tool
                }
            case "workbuddy":
                if appName.contains("workbuddy") || appBundleID.contains("workbuddy") {
                    return tool
                }
            case "grok-bot", "grokbot":
                if appName == "grok bot" || appBundleID == "com.anysphere.sand" || appBundleID.contains("sand") {
                    return tool
                }
            case "grok-web", "grok":
                if appName == "grok" || appBundleID.contains("e0ef637e") {
                    return tool
                }
            case "hermes":
                if appName.contains("hermes") || appBundleID.contains("hermes") {
                    return tool
                }
            default:
                break
            }

            // Web PWA candidate
            if tool.kind == .web && appBundleID.contains("safari.webapp") {
                if appName == tool.name.lowercased() {
                    return tool
                }
            }
        }
        return nil
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
        case "grok-web", "grok", "gemini-web", "gemini", "chatgpt-web":
            // Web apps (PWAs) have machine-specific bundle IDs: set them in config.json.
            if let explicit = tool.bundleIdentifier, !explicit.isEmpty {
                return [explicit]
            }
            return []
        default:
            return []
        }
    }

    private func attach(to app: NSRunningApplication) -> Bool {
        if isBrowserApplication(app) {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var rawValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue) == .success,
                  let axWindows = rawValue as? [AXUIElement] else { return false }

            let visibleWindows = axWindows.filter { win in
                let role = stringAttribute(win, kAXRoleAttribute as CFString)
                guard role == "AXWindow" else { return false }
                let subrole = stringAttribute(win, kAXSubroleAttribute as CFString)
                if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" { return false }
                return !boolAttribute(win, kAXMinimizedAttribute as CFString)
            }

            guard let frontWindow = visibleWindows.first else { return false }
            let frontTitle = stringAttribute(frontWindow, kAXTitleAttribute as CFString) ?? ""
            let frontDoc = stringAttribute(frontWindow, "AXDocument" as CFString) ?? stringAttribute(frontWindow, "AXURL" as CFString) ?? ""

            func toolMatches(tool: ToolItem) -> Bool {
                if let u = tool.url, let host = URL(string: u)?.host {
                    let cleanHost = host.replacingOccurrences(of: "www.", with: "")
                    if !cleanHost.isEmpty && !frontDoc.isEmpty {
                        if frontDoc.localizedCaseInsensitiveContains(cleanHost) {
                            return true
                        }
                        if frontDoc.lowercased().hasPrefix("http://") || frontDoc.lowercased().hasPrefix("https://") {
                            return false
                        }
                    }
                }
                return tool.titleHints.contains(where: { frontTitle.localizedCaseInsensitiveContains($0) })
            }

            // 1. Prioritize currently selected tool if its hints or document match
            if let selID = selectedToolID,
               let currentTool = configStore.configuration.tools.first(where: { $0.id == selID && $0.kind == .web }),
               toolMatches(tool: currentTool) {
                return attachToWindow(frontWindow, app: app, tool: currentTool)
            }

            // 2. Otherwise match against any enabled web tool
            for tool in configStore.configuration.tools where tool.enabled && tool.kind == .web {
                if toolMatches(tool: tool) {
                    return attachToWindow(frontWindow, app: app, tool: tool)
                }
            }

            // 3. Fallback: match by active Chrome tab URL via AppleScript if AXDocument was missing
            if let tabURL = activeChromeTabURL() {
                for tool in configStore.configuration.tools where tool.enabled && tool.kind == .web {
                    if let u = tool.url, let host = URL(string: u)?.host {
                        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
                        if !cleanHost.isEmpty && tabURL.localizedCaseInsensitiveContains(cleanHost) {
                            return attachToWindow(frontWindow, app: app, tool: tool)
                        }
                    }
                }
            }

            return false
        }

        guard let tool = registeredTool(for: app) else { return false }
        let windows = standardWindows(for: app, tool: tool)
        if let window = preferredWindow(from: windows, app: app) {
            return attachToWindow(window, app: app, tool: tool)
        }
        return false
    }

    @discardableResult
    private func attachToWindow(_ window: AXUIElement, app: NSRunningApplication, tool: ToolItem) -> Bool {
        let generation = switchGeneration
        let wasHidden = app.isHidden
        let wasMinimized = boolAttribute(window, kAXMinimizedAttribute as CFString)
        if wasHidden || wasMinimized {
            windowTracker.markRestoring(duration: 1.2)
        }

        selectedToolID = tool.id
        isMinimized = false
        railWindowController?.applyAppearance(for: tool)

        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let currentActual = windowFrame(window)
        let slot = workspaceSlot(preferred: canonicalStackFrame, fallback: currentActual)
        let effectiveFrame = clampToCanonicalConstraints(slot)

        // Place first, reveal second. This prevents a newly launched/hidden app from
        // appearing at its own default macOS location and then visibly jumping.
        setFrame(window, nsFrame: effectiveFrame)

        if wasHidden {
            setAppHidden(app, false)
        }
        if wasMinimized {
            setMinimized(window, false)
        }

        // Re-assert after reveal because some Electron apps restore their saved frame
        // during deminiaturization/unhide.
        setFrame(window, nsFrame: effectiveFrame)

        // The rail follows where the window actually ended up, not where it was asked to
        // go. Apps that refuse a size/position otherwise leave the rail over their content.
        let placedFrame = adoptActualFrame(of: window, requested: effectiveFrame)
        windowTracker.startTracking(app: app, window: window, tool: tool)
        moveRail(alongside: placedFrame, railWidth: railWidth)

        let targetWid = Self.windowID(for: window)
        let sameApp = windowTracker.currentApp?.processIdentifier == app.processIdentifier
        bringWindowToFront(window, app: app, forceActivate: !sameApp)
        orderAdjacentToTargetWindow(targetWindowID: targetWid)
        hideOtherRegisteredApps(except: tool, activeApp: app)

        if wasMinimized || wasHidden {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, self.switchGeneration == generation,
                      !self.isMinimized, self.selectedToolID == tool.id,
                      self.currentTargetWindowID == targetWid,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self.setFrame(window, nsFrame: self.canonicalStackFrame ?? effectiveFrame)
                self.bringWindowToFront(window, app: app, forceActivate: false)
                self.windowTracker.checkWindowFrame(force: true)
                self.orderAdjacentToTargetWindow(targetWindowID: targetWid)
            }
        }

        return true
    }

    private func alignSameAppRegisteredWindows(to frame: CGRect, activeTool: ToolItem, activeWindow: AXUIElement?) {
        stackRegisteredWindows(onto: frame, activeTool: activeTool, activeWindow: activeWindow)
    }

    // TODO: Implement AppleScript Chrome tab URL fallback when AXDocument is unavailable.
    // Currently a no-op stub. Callers use AXDocument/AXURL as primary path (works on Chrome 120+).
    private func getChromeWindowTabURLs(maxAge: TimeInterval = 0.5) -> [String: String] {
        return [:]
    }

    // TODO: Implement AppleScript active Chrome tab URL fallback.
    private func activeChromeTabURL() -> String? {
        return nil
    }

    private func cancelPendingSwitchWork() {
        switchGeneration &+= 1
        minimumVerificationTask?.cancel()
        minimumVerificationTask = nil
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
        pendingActivationTask?.cancel()
        pendingActivationTask = nil
        pendingHideTask?.cancel()
        pendingHideTask = nil
        isSwitchingTool = false
        launchingToolID = nil
    }

    private func reconcileFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        handleAppActivation(Notification(
            name: NSWorkspace.didActivateApplicationNotification,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        ))
    }

    private func scheduleSwitchCompletion(generation: UInt) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.switchGeneration == generation else { return }
            self.isSwitchingTool = false
            // Also recover if the system coalesced/delayed an activation notification.
            self.reconcileFrontmostApplication()
        }
    }

    func switchTo(_ tool: ToolItem) {
        guard tool.enabled else { return }
        NSLog("[ToolSwitchRail] switchTo requested: %@", tool.name)

        guard AccessibilityPermission.isTrusted else {
            NSLog("[ToolSwitchRail] Accessibility permission NOT trusted! Prompting alert.")
            // Never a blocking dialog: a quiet hint with a direct way to fix it.
            ToastCenter.shared.show("需要辅助功能权限才能对齐窗口", actionTitle: "去设置") {
                RailActions.openAccessibilitySettings()
            }
            return
        }

        cancelPendingSwitchWork()
        let generation = switchGeneration

        if selectedToolID == tool.id,
           windowTracker.currentTool?.id == tool.id,
           let curWin = windowTracker.currentWindow,
           let curApp = windowTracker.currentApp,
           !curApp.isHidden, !isMinimized,
           !boolAttribute(curWin, kAXMinimizedAttribute as CFString) {
            activateApp(curApp)
            AXUIElementPerformAction(curWin, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(curWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(curWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            railWindowController?.setFloatingForManagedTool(true)
            return
        }

        if isMinimized {
            isMinimized = false
            railWindowController?.show()
        }
        lastError = nil
        selectedToolID = tool.id
        railWindowController?.applyAppearance(for: tool)
        windowTracker.updateRailWidth(CGFloat(configStore.configuration.workspace.railWidth))

        let targetContentFrame = self.activeContentFrame ?? self.workspaceGeometry().content

        // 1. Existing window: place and activate without waiting for a launch.
        if let match = self.findWindow(for: tool) {
            NSLog("[ToolSwitchRail] Found existing window for %@ (instant switch)", tool.name)
            isSwitchingTool = true
            self.focus(match, contentFrame: targetContentFrame, tool: tool)
            scheduleSwitchCompletion(generation: generation)
            return
        }

        // 2. SLOW PATH: Tool not running yet -> launch without foreground activation,
        // place the first matching window, then activate only the requested tool.
        isSwitchingTool = true
        launchingToolID = tool.id

        pendingSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var focusedWindow = false
            defer {
                if self.switchGeneration == generation {
                    self.pendingSwitchTask = nil
                    self.launchingToolID = nil
                    if !focusedWindow {
                        self.isSwitchingTool = false
                        self.reconcileFrontmostApplication()
                    }
                }
            }
            do {
                NSLog("[ToolSwitchRail] Launching tool: %@", tool.name)
                try self.launch(tool)
                if let match = await self.waitForWindow(for: tool, timeout: 15.0) {
                    guard !Task.isCancelled, self.switchGeneration == generation else { return }
                    NSLog("[ToolSwitchRail] Window appeared after launch for %@", tool.name)
                    self.focus(match, contentFrame: targetContentFrame, tool: tool)
                    focusedWindow = true
                    self.scheduleSwitchCompletion(generation: generation)
                } else {
                    guard !Task.isCancelled, self.switchGeneration == generation else { return }
                    self.lastError = "没找到 \(tool.name) 的窗口"
                    ToastCenter.shared.show("没找到「\(tool.name)」的窗口", actionTitle: "重试") { [weak self] in
                        self?.switchTo(tool)
                    }
                    NSLog("[ToolSwitchRail] Error: %@", self.lastError ?? "")
                }
            } catch {
                self.lastError = error.localizedDescription
                ToastCenter.shared.show("打不开「\(tool.name)」", actionTitle: "重试") { [weak self] in
                    self?.switchTo(tool)
                }
                NSLog("[ToolSwitchRail] Catch error: %@", self.lastError ?? "")
            }
        }
    }

    // MARK: - Minimize / Restore

    func minimizeAll() {
        switchGeneration &+= 1
        minimumVerificationTask?.cancel()
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
        isSwitchingTool = false
        launchingToolID = nil
        if isMinimized { return }
        isMinimized = true
        ignoreActivationUntil = Date().addingTimeInterval(2.0)
        pendingActivationTask?.cancel()
        pendingActivationTask = nil
        minimumVerificationTask?.cancel()
        windowTracker.markRestoring(duration: 2.0)
        railWindowController?.hide()
        windowTracker.stopTracking(keepLastFrame: true)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var nativeAppsByPID: [pid_t: NSRunningApplication] = [:]
        var browserWindows: [AXUIElement] = []

        // Collect first, then perform the visibility changes. Native apps are hidden
        // as whole processes instead of being animated window-by-window into the Dock.
        for tool in configStore.configuration.tools where tool.enabled {
            for app in runningApplications(for: tool) {
                let pid = app.processIdentifier
                if pid == selfPID { continue }

                let appName = (app.localizedName ?? "").lowercased()
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                if appName.contains("rustdesk") || bundleID.contains("rustdesk") { continue }
                if isConfiguredBrowser(app) { continue }

                if isBrowserApplication(app) {
                    for win in standardWindows(for: app, tool: tool) {
                        if browserWindows.contains(where: { CFEqual($0, win) }) { continue }
                        if boolAttribute(win, kAXMinimizedAttribute as CFString) { continue }
                        browserWindows.append(win)
                    }
                } else {
                    nativeAppsByPID[pid] = app
                }
            }
        }

        // Hide native tools first: no per-window minimize animation.
        for app in nativeAppsByPID.values {
            setAppHidden(app, true)
        }

        // Chrome may also contain unrelated windows, so we must not hide the whole
        // browser process. Only the registered web-app windows are minimized.
        for win in browserWindows {
            setMinimized(win, true)
        }
    }

    private func scanForExternalMinimize() {
        refreshOpenTools()
    }

    func refreshOpenTools() {
        var ids = Set<String>()
        for tool in configStore.configuration.tools where tool.enabled {
            if toolIsOpen(tool) {
                ids.insert(tool.id)
            }
        }
        if ids != openToolIDs {
            openToolIDs = ids
        }
    }

    private func toolIsOpen(_ tool: ToolItem) -> Bool {
        if tool.kind == .app {
            return runningApplications(for: tool).contains { !$0.isTerminated }
        }
        return findWindow(for: tool) != nil
    }

    func minimizeCurrent() {
        minimizeAll()
    }

    func restoreCurrent() {
        if !isMinimized {
            railWindowController?.show()
            return
        }
        isMinimized = false
        ignoreActivationUntil = Date().addingTimeInterval(1.5)
        windowTracker.markRestoring(duration: 1.5)
        railWindowController?.show()

        let tool = activeTool
            ?? selectedToolID.flatMap { id in configStore.configuration.tools.first(where: { $0.id == id }) }
            ?? configStore.configuration.tools.first(where: { $0.enabled })
        guard let tool else { return }
        // Restore only the selected tool. Siblings stay hidden/minimized.
        switchTo(tool)
    }

    func toggleMinimize() {
        if isMinimized {
            restoreCurrent()
        } else {
            minimizeCurrent()
        }
    }

    // MARK: - Maximize / Zoom

    private var isMaximized = false
    private var unmaximizedContentFrame: CGRect?
    private var unmaximizedRailFrame: CGRect?

    func toggleMaximize() {
        guard let target = windowTracker.currentWindow else { return }
        let screen = screenContainingRail() ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)

        if isMaximized {
            isMaximized = false
            let restoreContent = unmaximizedContentFrame ?? workspaceGeometry().content
            let restoreRail = CGRect(
                x: restoreContent.minX - railWidth,
                y: restoreContent.minY,
                width: railWidth,
                height: restoreContent.height
            )
            setFrame(target, nsFrame: restoreContent)
            activeContentFrame = restoreContent
            if let tool = windowTracker.currentTool {
                stackRegisteredWindows(onto: restoreContent, activeTool: tool, activeWindow: target, verify: true)
            }
            railWindowController?.move(to: restoreRail)
            windowTracker.checkWindowFrame(force: true)
        } else {
            unmaximizedContentFrame = activeContentFrame ?? windowFrame(target)
            unmaximizedRailFrame = railWindowController?.window?.frame

            let unifiedContentFrame = CGRect(
                x: visible.minX + railWidth,
                y: visible.minY,
                width: visible.width - railWidth,
                height: visible.height
            )
            let unifiedRailFrame = CGRect(
                x: visible.minX,
                y: visible.minY,
                width: railWidth,
                height: visible.height
            )

            isMaximized = true
            activeContentFrame = unifiedContentFrame
            setFrame(target, nsFrame: unifiedContentFrame)
            if let tool = windowTracker.currentTool {
                stackRegisteredWindows(onto: unifiedContentFrame, activeTool: tool, activeWindow: target, verify: true)
            }
            railWindowController?.move(to: unifiedRailFrame)
            windowTracker.checkWindowFrame(force: true)
        }
    }

    // MARK: - Window Edge Resizing

    func beginRailResize() {
        windowTracker.isRailDragging = true
        lastLiveStackSyncTime = 0
        lastLiveStackFrame = nil
        if isMaximized {
            isMaximized = false
        }
    }

    func handleRailResize(
        isLeft: Bool,
        isBottom: Bool,
        isTop: Bool,
        dx: CGFloat,
        dy: CGFloat,
        startRailFrame: CGRect,
        startTargetFrame: CGRect
    ) {
        let minSize = compatibilityMinSize
        let minContentW: CGFloat = minSize.width
        let minContentH: CGFloat = minSize.height
        let railW = startRailFrame.width

        var newRailX = startRailFrame.minX
        var newRailY = startRailFrame.minY
        var newHeight = startRailFrame.height

        var newTargetX = startTargetFrame.minX
        var newTargetY = startTargetFrame.minY
        var newTargetW = startTargetFrame.width
        var newTargetH = startTargetFrame.height

        // Left edge resizing (pulling left edge widens/narrows from the left)
        if isLeft {
            let rightAnchor = startTargetFrame.maxX
            newRailX = min(startRailFrame.minX + dx, rightAnchor - railW - minContentW)
            newTargetX = newRailX + railW
            newTargetW = max(minContentW, rightAnchor - newTargetX)
        }

        // Bottom edge resizing (pulling bottom edge down increases height, up decreases)
        if isBottom {
            let topAnchor = startRailFrame.maxY
            newRailY = min(startRailFrame.minY + dy, topAnchor - minContentH)
            newHeight = max(minContentH, topAnchor - newRailY)
            newTargetY = newRailY
            newTargetH = newHeight
        }

        // Top edge resizing (pulling top edge up increases height, down decreases)
        if isTop {
            let bottomAnchor = startRailFrame.minY
            newHeight = max(minContentH, startRailFrame.height + dy)
            newTargetH = newHeight
            newRailY = bottomAnchor
            newTargetY = bottomAnchor
        }

        let newRailFrame = CGRect(x: newRailX, y: newRailY, width: railW, height: newHeight)
        let newTargetFrame = CGRect(x: newTargetX, y: newTargetY, width: newTargetW, height: newTargetH)

        railWindowController?.move(to: newRailFrame)

        if let target = windowTracker.currentWindow {
            setFrame(target, nsFrame: newTargetFrame)
            activeContentFrame = newTargetFrame
            if let tool = windowTracker.currentTool {
                liveSyncBackgroundWindows(to: newTargetFrame, activeTool: tool, activeWindow: target)
            }
        }
    }

    func endRailResize() {
        windowTracker.isRailDragging = false
        windowTracker.checkWindowFrame(force: true)
        orderAdjacentToTargetWindow()
        if let targetFrame = activeContentFrame,
           let tool = windowTracker.currentTool,
           let target = windowTracker.currentWindow {
            stackRegisteredWindows(onto: targetFrame, activeTool: tool, activeWindow: target, verify: true)
        }
        lastLiveStackFrame = nil
    }

    func resizeToPreset(width: CGFloat, height: CGFloat) {
        guard let target = windowTracker.currentWindow else { return }
        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let current = canonicalStackFrame ?? activeContentFrame ?? windowFrame(target) ?? workspaceGeometry().content
        let minSize = compatibilityMinSize

        let targetW = max(minSize.width, width - railWidth)
        let targetH = max(minSize.height, height)
        let rawContent = CGRect(
            x: current.minX,
            y: current.minY,
            width: targetW,
            height: targetH
        )
        let clampedContent = clampToCanonicalConstraints(rawContent)
        let newRail = CGRect(
            x: clampedContent.minX - railWidth,
            y: clampedContent.minY,
            width: railWidth,
            height: clampedContent.height
        )

        isMaximized = false
        canonicalStackFrame = clampedContent
        activeContentFrame = clampedContent
        setFrame(target, nsFrame: clampedContent)
        railWindowController?.move(to: newRail)
        if let tool = windowTracker.currentTool {
            stackRegisteredWindows(onto: clampedContent, activeTool: tool, activeWindow: target, verify: true)
        }
        windowTracker.checkWindowFrame(force: true)
    }

    func resetToDefaultGeometry() {
        let geo = workspaceGeometry()
        if let target = windowTracker.currentWindow {
            setFrame(target, nsFrame: geo.content)
        }
        isMaximized = false
        railWindowController?.move(to: geo.rail)
        activeContentFrame = geo.content
        if let tool = windowTracker.currentTool, let target = windowTracker.currentWindow {
            stackRegisteredWindows(onto: geo.content, activeTool: tool, activeWindow: target, verify: true)
        }
        windowTracker.checkWindowFrame(force: true)
    }

    // MARK: - Unified Window Dragging

    func handleRailDrag(translation: CGSize) {
        guard let railWindow = railWindowController?.window else { return }

        if dragStartRailOrigin == nil {
            dragStartRailOrigin = railWindow.frame.origin
            dragStartAXPoint = windowTracker.currentWindowAXPosition()
            dragStartContentFrame = canonicalStackFrame ?? activeContentFrame ?? windowTracker.currentWindow.flatMap(windowFrame)
            windowTracker.isRailDragging = true
            lastLiveStackSyncTime = 0
            lastLiveStackFrame = nil
        }

        guard let startRail = dragStartRailOrigin else { return }

        // AppKit screen coordinates: moving down decreases y
        let newRailOrigin = CGPoint(
            x: startRail.x + translation.width,
            y: startRail.y - translation.height
        )
        railWindowController?.setOrigin(newRailOrigin)

        // If an official app window is currently attached, move it synchronously
        if let startAX = dragStartAXPoint, let target = windowTracker.currentWindow {
            // AX screen coordinates: moving down increases y
            var newAXPoint = CGPoint(
                x: startAX.x + translation.width,
                y: startAX.y + translation.height
            )
            if let pointVal = AXValueCreate(.cgPoint, &newAXPoint) {
                AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, pointVal)
            }

            if let startContent = dragStartContentFrame,
               let tool = windowTracker.currentTool {
                let newContentFrame = startContent.offsetBy(dx: translation.width, dy: -translation.height)
                canonicalStackFrame = newContentFrame
                liveSyncBackgroundWindows(to: newContentFrame, activeTool: tool, activeWindow: target)
            }
        }
    }

    func endRailDrag() {
        windowTracker.isRailDragging = false
        dragStartRailOrigin = nil
        dragStartAXPoint = nil
        dragStartContentFrame = nil

        windowTracker.checkWindowFrame(force: true)
        orderAdjacentToTargetWindow()
        if let targetFrame = activeContentFrame,
           let tool = windowTracker.currentTool,
           let target = windowTracker.currentWindow {
            stackRegisteredWindows(onto: targetFrame, activeTool: tool, activeWindow: target, verify: true)
        }
        lastLiveStackFrame = nil
    }

    func workspaceGeometry() -> (rail: CGRect, content: CGRect) {
        let cfg = configStore.configuration.workspace
        let screen = screenContainingRail() ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        let minSize = compatibilityMinSize
        let totalWidth = min(
            visible.width - 24,
            max(minSize.width, visible.width * cfg.widthFraction)
        )
        let height = min(
            visible.height - 24,
            max(minSize.height, visible.height * cfg.heightFraction)
        )

        let railWidth = CGFloat(cfg.railWidth)
        let x = max(visible.minX, visible.midX - totalWidth / 2)
        let y = visible.midY - height / 2

        let rail = CGRect(x: x, y: y, width: railWidth, height: height)
        let content = CGRect(x: x + railWidth, y: y, width: min(visible.maxX - (x + railWidth), totalWidth - railWidth), height: height)
        return (rail, content)
    }

    private func screenContainingRail() -> NSScreen? {
        guard let frame = railWindowController?.window?.frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
    }

    private func launch(_ tool: ToolItem) throws {
        switch tool.kind {
        case .app:
            if let bundleID = resolvedBundleIdentifier(for: tool),
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                // Do not foreground a new app until its first real window is placed in
                // canonicalStackFrame. focus(...) activates it after placement.
                config.activates = false
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                    if let error {
                        print("[WindowManager] Open app failed: \(error)")
                    }
                }
                return
            }

            if let appName = tool.appName, !appName.isEmpty {
                // -g opens without bringing the application to the foreground.
                try runOpen(arguments: ["-g", "-a", appName])
                return
            }

            throw RailError.invalidConfiguration("\(tool.name) 缺少有效的 appName 或 bundleIdentifier")

        case .web:
            // 1. Check if tool has explicit or resolved bundleIdentifier for a standalone Web App / PWA
            if let bundleID = tool.bundleIdentifier ?? resolvedBundleIdentifier(for: tool),
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                    if let error {
                        print("[WindowManager] Open webapp failed: \(error)")
                    }
                }
                return
            }

            // 2. Check if a standalone app exists in ~/Applications/Chrome Apps.localized, ~/Applications or /Applications
            let candidates = [
                NSString(string: "~/Applications/Chrome Apps.localized/\(tool.name).app").expandingTildeInPath,
                NSString(string: "~/Applications/Chrome Apps.localized/\(tool.appName ?? "").app").expandingTildeInPath,
                NSString(string: "~/Applications/\(tool.name).app").expandingTildeInPath,
                NSString(string: "~/Applications/\(tool.appName ?? "").app").expandingTildeInPath,
                "/Applications/\(tool.name).app"
            ].filter { !$0.hasSuffix("/.app") }

            for path in candidates where FileManager.default.fileExists(atPath: path) {
                try runOpen(arguments: ["-g", path])
                return
            }

            // 3. Fallback to normal system URL open without managing browser
            guard let url = tool.url, !url.isEmpty, let targetURL = URL(string: url) else {
                throw RailError.invalidConfiguration("\(tool.name) 缺少 url")
            }
            NSWorkspace.shared.open(targetURL)
        }
    }

    private func launchBrowserApp(urlString: String) throws {
        let browser = configStore.configuration.browser

        let isBrowserRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == (browser.bundleIdentifier ?? "com.google.Chrome") ||
            $0.localizedName?.localizedCaseInsensitiveCompare(browser.appName) == .orderedSame
        }

        if isBrowserRunning {
            let script = """
            tell application "\(browser.appName)"
                set newWin to make new window
                set URL of active tab of newWin to "\(urlString)"
                activate
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error == nil {
                    return
                }
            }
        }

        try runOpen(arguments: ["-a", browser.appName, "--args", "--app=\(urlString)", "--new-window"])
    }

    private func runOpen(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
    }

    private func waitForWindow(for tool: ToolItem, timeout: TimeInterval) async -> WindowMatch? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return nil }
            if let match = findWindow(for: tool) {
                return match
            }
            // Poll quickly only during launch so the first frame can be placed before
            // the user sees a default-position flash.
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return nil
    }

    private func findWindow(for tool: ToolItem) -> WindowMatch? {
        let apps = runningApplications(for: tool)
        for app in apps {
            let windows = standardWindows(for: app, tool: tool)
            if let window = preferredWindow(from: windows, app: app) {
                return WindowMatch(app: app, window: window)
            }
        }
        return nil
    }

    private func runningApplications(for tool: ToolItem) -> [NSRunningApplication] {
        let workspace = NSWorkspace.shared

        switch tool.kind {
        case .app:
            var apps: [NSRunningApplication] = []

            if let bundleID = resolvedBundleIdentifier(for: tool) {
                apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
            }

            for altID in alternativeBundleIdentifiers(for: tool) {
                if !apps.contains(where: { $0.bundleIdentifier == altID }) {
                    apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: altID))
                }
            }

            let candidateNames = [tool.appName, tool.name, tool.id].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
            if apps.isEmpty {
                let matching = workspace.runningApplications.filter { app in
                    guard let name = app.localizedName?.lowercased() else { return false }
                    return candidateNames.contains(where: { name == $0 || name.contains($0) || $0.contains(name) })
                }
                apps.append(contentsOf: matching)
            }

            // Fallbacks for known tools
            if apps.isEmpty {
                switch tool.id.lowercased() {
                case "wps-lingxi", "wpslingxi", "lingxi":
                    apps.append(contentsOf: workspace.runningApplications.filter {
                        ($0.localizedName?.contains("灵犀") == true) || ($0.bundleIdentifier?.contains("lingxi") == true)
                    })
                case "antigravity":
                    apps.append(contentsOf: workspace.runningApplications.filter {
                        ($0.localizedName?.lowercased().contains("antigravity") == true) || ($0.bundleIdentifier?.contains("antigravity") == true)
                    })
                case "codex", "chatgpt", "chatgpt-app", "chatgpt-mac":
                    apps.append(contentsOf: workspace.runningApplications.filter {
                        ($0.localizedName?.lowercased() == "chatgpt") || ($0.bundleIdentifier == "com.openai.codex")
                    })
                default:
                    break
                }
            }

            var seenPIDs = Set<pid_t>()
            return apps.filter { seenPIDs.insert($0.processIdentifier).inserted }

        case .web:
            var apps: [NSRunningApplication] = []

            if let explicit = tool.bundleIdentifier ?? resolvedBundleIdentifier(for: tool) {
                apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: explicit))
            }
            for altID in alternativeBundleIdentifiers(for: tool) {
                if !apps.contains(where: { $0.bundleIdentifier == altID }) {
                    apps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: altID))
                }
            }

            // Web tools are managed only as standalone web-app (PWA) processes. The general
            // browser is never part of a tool, otherwise unrelated Chrome windows whose title
            // contains "Gemini"/"Grok" get moved, resized or hidden.

            let hints = tool.titleHints
            for app in workspace.runningApplications {
                if apps.contains(where: { $0.processIdentifier == app.processIdentifier }) { continue }
                if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { continue }
                if isBrowserApplication(app) || isConfiguredBrowser(app) { continue }
                if let registered = registeredTool(for: app), registered.id != tool.id { continue }

                let name = app.localizedName ?? ""
                let bundleID = app.bundleIdentifier ?? ""
                let isWebAppProcess = bundleID.hasPrefix("com.apple.Safari.WebApp")
                    || bundleID.contains("Chrome.app.")
                    || bundleID.lowercased().contains("chrom")

                let nameHit = hints.contains { name.localizedCaseInsensitiveContains($0) }
                    || name.localizedCaseInsensitiveCompare(tool.name) == .orderedSame
                if nameHit && (isWebAppProcess || !bundleID.hasPrefix("com.apple.")) {
                    apps.append(app)
                }
            }

            var seenPIDs = Set<pid_t>()
            return apps.filter { seenPIDs.insert($0.processIdentifier).inserted }
        }
    }

    private func resolvedBundleIdentifier(for tool: ToolItem) -> String? {
        if let explicit = tool.bundleIdentifier, !explicit.isEmpty {
            return explicit
        }
        switch tool.id.lowercased() {
        case "codex", "chatgpt", "chatgpt-app", "chatgpt-mac": return "com.openai.codex"
        case "workbuddy": return "com.tencent.workbuddy.mac"
        case "hermes": return "com.nousresearch.hermes"
        case "antigravity": return "com.google.antigravity"
        case "grok-bot", "grokbot": return "com.anysphere.sand"
        case "wps-lingxi", "wpslingxi", "lingxi": return "com.wps.lingxi"
        case "grok-web", "grok", "gemini-web", "gemini", "chatgpt-web":
            return tool.bundleIdentifier
        default: return nil
        }
    }

    private func standardWindows(for app: NSRunningApplication, tool: ToolItem) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success,
        let windows = rawValue as? [AXUIElement] else {
            return []
        }

        let validWindows = windows.filter { window in
            let role = stringAttribute(window, kAXRoleAttribute as CFString)
            guard role == "AXWindow" else { return false }

            let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
            if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" {
                return false
            }

            // Exclude dummy 0x0 startup windows
            let isMin = boolAttribute(window, kAXMinimizedAttribute as CFString)
            if !isMin, let frame = windowFrame(window) {
                if frame.width < 100 || frame.height < 100 {
                    return false
                }
            }
            return true
        }

        if tool.kind == .web {
            let hints = tool.titleHints
            var matching: [AXUIElement] = []

            var cleanHost: String? = nil
            if let targetURL = tool.url, let host = URL(string: targetURL)?.host {
                let h = host.replacingOccurrences(of: "www.", with: "")
                if !h.isEmpty {
                    cleanHost = h
                }
            }

            for window in validWindows {
                let doc = stringAttribute(window, "AXDocument" as CFString) ?? stringAttribute(window, "AXURL" as CFString) ?? ""

                // 1. Direct AXDocument URL check (instant, zero IPC, immune to chat renaming)
                if let host = cleanHost, !doc.isEmpty {
                    if doc.localizedCaseInsensitiveContains(host) {
                        matching.append(window)
                        continue
                    } else if doc.lowercased().hasPrefix("http://") || doc.lowercased().hasPrefix("https://") {
                        // Belongs to a different web domain, skip
                        continue
                    }
                }

                // 2. Title hints fallback
                let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
                if !hints.isEmpty && hints.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                    matching.append(window)
                    continue
                }
            }

            // 3. AppleScript tab URL fallback if AXDocument was unsupported
            if matching.isEmpty, isBrowserApplication(app), let host = cleanHost {
                let urlMap = getChromeWindowTabURLs()
                for window in validWindows {
                    let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
                    for (tabTitle, tabURL) in urlMap {
                        if (title.contains(tabTitle) || tabTitle.contains(title)) && tabURL.localizedCaseInsensitiveContains(host) {
                            matching.append(window)
                            break
                        }
                    }
                }
            }

            if !matching.isEmpty {
                return matching
            }

            if !validWindows.isEmpty && app.bundleIdentifier != configStore.configuration.browser.bundleIdentifier {
                return validWindows
            }
            return []
        }

        let hints = tool.titleHints
        if !hints.isEmpty {
            let matching = validWindows.filter { window in
                let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
                return hints.contains { hint in
                    title.localizedCaseInsensitiveContains(hint)
                }
            }
            if !matching.isEmpty {
                return matching
            }
        }

        return validWindows
    }

    /// The window the user is actually looking at (the app's focused window) wins over
    /// "main"; with several windows the rail otherwise tracks a window that is not visible.
    private func preferredWindow(from windows: [AXUIElement], app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let focusedWindow = focused as! AXUIElement
            if let match = windows.first(where: { CFEqual($0, focusedWindow) }),
               !boolAttribute(match, kAXMinimizedAttribute as CFString) {
                return match
            }
        }
        return preferredWindow(from: windows)
    }

    private func preferredWindow(from windows: [AXUIElement]) -> AXUIElement? {
        if let mainWin = windows.first(where: { boolAttribute($0, kAXMainAttribute as CFString) && !boolAttribute($0, kAXMinimizedAttribute as CFString) }) {
            return mainWin
        }
        if let unminimized = windows.first(where: { !boolAttribute($0, kAXMinimizedAttribute as CFString) }) {
            return unminimized
        }
        return windows.first
    }

    private func focus(_ match: WindowMatch, contentFrame: CGRect, tool: ToolItem) {
        let generation = switchGeneration
        let wasHidden = match.app.isHidden
        let wasMinimized = boolAttribute(match.window, kAXMinimizedAttribute as CFString)
        if wasHidden || wasMinimized {
            windowTracker.markRestoring(duration: 1.2)
        }

        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let currentActual = windowFrame(match.window)
        let slot = workspaceSlot(preferred: canonicalStackFrame ?? contentFrame, fallback: currentActual)
        let effectiveFrame = clampToCanonicalConstraints(slot)

        isMinimized = false

        // Place while hidden/minimized first so the requested tool does not flash at
        // its saved/default position before joining the workspace.
        setFrame(match.window, nsFrame: effectiveFrame)

        if wasHidden {
            setAppHidden(match.app, false)
        }
        if wasMinimized {
            setMinimized(match.window, false)
        }
        setFrame(match.window, nsFrame: effectiveFrame)

        let placedFrame = adoptActualFrame(of: match.window, requested: effectiveFrame)
        moveRail(alongside: placedFrame, railWidth: railWidth)

        let targetWindowID = Self.windowID(for: match.window)
        let sameApp = windowTracker.currentApp?.processIdentifier == match.app.processIdentifier

        windowTracker.startTracking(app: match.app, window: match.window, tool: tool)

        bringWindowToFront(match.window, app: match.app, forceActivate: !sameApp)
        orderAdjacentToTargetWindow(targetWindowID: targetWindowID)
        hideOtherRegisteredApps(except: tool, activeApp: match.app)

        if wasMinimized || wasHidden {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, self.switchGeneration == generation,
                      !self.isMinimized, self.selectedToolID == tool.id,
                      self.currentTargetWindowID == targetWindowID,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == match.app.processIdentifier else { return }
                self.setFrame(match.window, nsFrame: self.canonicalStackFrame ?? effectiveFrame)
                self.bringWindowToFront(match.window, app: match.app, forceActivate: false)
                self.windowTracker.checkWindowFrame(force: true)
                self.orderAdjacentToTargetWindow(targetWindowID: targetWindowID)
            }
        }
    }

    /// Switching shows exactly one tool. Other registered native apps are hidden as whole
    /// processes (no Dock animation, nothing peeking out behind the active window).
    /// Controlled by workspace.minimizeOtherRegisteredWindows (previously read nowhere).
    /// The general browser, RustDesk and this app are never touched.
    private func hideOtherRegisteredApps(except activeTool: ToolItem, activeApp: NSRunningApplication) {
        guard configStore.configuration.workspace.minimizeOtherRegisteredWindows else {
            let frame = activeContentFrame ?? workspaceGeometry().content
            stackRegisteredWindows(onto: frame, activeTool: activeTool, activeWindow: windowTracker.currentWindow)
            return
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<pid_t>()
        for tool in configStore.configuration.tools where tool.enabled && tool.id != activeTool.id {
            for app in runningApplications(for: tool) {
                let pid = app.processIdentifier
                if pid == selfPID || pid == activeApp.processIdentifier { continue }
                if !seen.insert(pid).inserted { continue }
                if isConfiguredBrowser(app) || isBrowserApplication(app) { continue }
                let name = (app.localizedName ?? "").lowercased()
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                if name.contains("rustdesk") || bundleID.contains("rustdesk") { continue }
                setAppHidden(app, true)
            }
        }
    }

    /// Reads the window's real frame after a placement request. If the app refused or
    /// clamped it, that real frame becomes the workspace frame.
    @discardableResult
    private func adoptActualFrame(of window: AXUIElement, requested: CGRect) -> CGRect {
        let actual = windowFrame(window) ?? requested
        canonicalStackFrame = actual
        return actual
    }

    private func moveRail(alongside frame: CGRect, railWidth: CGFloat) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main ?? NSScreen.screens.first
        let minX = screen?.visibleFrame.minX ?? (frame.minX - railWidth)
        railWindowController?.move(to: CGRect(
            x: max(frame.minX - railWidth, minX),
            y: frame.minY,
            width: railWidth,
            height: frame.height
        ))
    }

    private func allStandardWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success,
        let windows = rawValue as? [AXUIElement] else {
            return []
        }

        return windows.filter { window in
            let role = stringAttribute(window, kAXRoleAttribute as CFString)
            guard role == "AXWindow" else { return false }

            let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
            if subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" {
                return false
            }

            let isMin = boolAttribute(window, kAXMinimizedAttribute as CFString)
            if !isMin, let frame = windowFrame(window) {
                if frame.width < 100 || frame.height < 100 {
                    return false
                }
            }
            return true
        }
    }

    // Move/resize background members while the foreground frame is changing. This is
    // deliberately separate from stackRegisteredWindows: it never reveals siblings and
    // never raises/focuses them, so live movement does not create a visible cascade.
    private func liveSyncBackgroundWindows(
        to frame: CGRect,
        activeTool: ToolItem,
        activeWindow: AXUIElement?,
        force: Bool = false
    ) {
        // Hide-others mode (default): there are no visible siblings to align. Writing their
        // frames anyway made background apps jump and the stack grow ("learned minimum").
        if configStore.configuration.workspace.minimizeOtherRegisteredWindows { return }
        guard !isMinimized else { return }
        guard frame.width > 80, frame.height > 80 else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let sizeChanged: Bool
        if let previous = lastLiveStackFrame {
            sizeChanged = abs(previous.width - frame.width) >= 1 || abs(previous.height - frame.height) >= 1
        } else {
            sizeChanged = true
        }
        let minimumInterval: TimeInterval = sizeChanged ? (1.0 / 24.0) : (1.0 / 60.0)
        if !force && now - lastLiveStackSyncTime < minimumInterval { return }
        lastLiveStackSyncTime = now
        lastLiveStackFrame = frame

        let stacked = CGRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
        let tracked = activeWindow ?? windowTracker.currentWindow
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var seenWindows: [AXUIElement] = []

        for tool in configStore.configuration.tools where tool.enabled {
            for app in runningApplications(for: tool) {
                if app.processIdentifier == selfPID { continue }
                let appName = (app.localizedName ?? "").lowercased()
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                if appName.contains("rustdesk") || bundleID.contains("rustdesk") { continue }
                if app.isHidden && !isBrowserApplication(app) { continue }

                for win in standardWindows(for: app, tool: tool) {
                    if let tracked, CFEqual(win, tracked) { continue }
                    if seenWindows.contains(where: { CFEqual($0, win) }) { continue }
                    seenWindows.append(win)
                    if boolAttribute(win, kAXMinimizedAttribute as CFString) { continue }
                    setFrame(win, nsFrame: stacked)
                }
            }
        }
    }

    private func stackRegisteredWindows(onto frame: CGRect, activeTool: ToolItem, activeWindow: AXUIElement?, verify: Bool = false) {
        // Hide-others mode (default): there are no visible siblings to align. Writing their
        // frames anyway made background apps jump and the stack grow ("learned minimum").
        if configStore.configuration.workspace.minimizeOtherRegisteredWindows { return }
        guard !isMinimized else { return }
        guard frame.width > 80, frame.height > 80 else { return }

        let stacked = CGRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
        let tracked = activeWindow ?? windowTracker.currentWindow
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var didMoveAnyWindow = false
        var seenWindows: [AXUIElement] = []
        var verificationTargets: [(tool: ToolItem, window: AXUIElement)] = []

        for tool in configStore.configuration.tools where tool.enabled {
            let apps = runningApplications(for: tool)
            for app in apps {
                let pid = app.processIdentifier
                if pid == selfPID { continue }
                let appName = (app.localizedName ?? "").lowercased()
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                if appName.contains("rustdesk") || bundleID.contains("rustdesk") {
                    continue
                }

                // Warm stack alignment must never wake a hidden/minimized sibling.
                // Only the selected tool may be restored by focus/attach.
                if app.isHidden && !isBrowserApplication(app) { continue }
                let windows = standardWindows(for: app, tool: tool)

                for win in windows {
                    if seenWindows.contains(where: { CFEqual($0, win) }) { continue }
                    seenWindows.append(win)

                    if boolAttribute(win, kAXMinimizedAttribute as CFString) { continue }
                    if verify {
                        verificationTargets.append((tool: tool, window: win))
                    }
                    if let tracked, CFEqual(win, tracked) { continue }
                    if let current = windowFrame(win), framesAlmostEqual(current, stacked) {
                        continue
                    }
                    setFrame(win, nsFrame: stacked)
                    didMoveAnyWindow = true
                }
            }
        }

        if verify,
           let tracked,
           !verificationTargets.contains(where: { CFEqual($0.window, tracked) }) {
            verificationTargets.append((tool: activeTool, window: tracked))
        }

        if didMoveAnyWindow, let tracked {
            AXUIElementPerformAction(tracked, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(tracked, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(tracked, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        if verify {
            scheduleMinimumVerification(
                requestedFrame: stacked,
                targets: verificationTargets,
                activeTool: activeTool,
                activeWindow: tracked
            )
        }
    }

    private func scheduleMinimumVerification(
        requestedFrame: CGRect,
        targets: [(tool: ToolItem, window: AXUIElement)],
        activeTool: ToolItem,
        activeWindow: AXUIElement?
    ) {
        minimumVerificationTask?.cancel()
        let generation = switchGeneration
        minimumVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  self.switchGeneration == generation,
                  !self.isMinimized,
                  self.selectedToolID == activeTool.id,
                  let activeWindow,
                  let currentWindow = self.windowTracker.currentWindow,
                  CFEqual(activeWindow, currentWindow),
                  let currentApp = self.windowTracker.currentApp,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == currentApp.processIdentifier,
                  !self.windowTracker.isRailDragging,
                  !self.windowTracker.isMouseDragging else { return }

            var learnedSomething = false
            for target in targets {
                guard let actual = self.windowFrame(target.window) else { continue }
                var learned = self.learnedMinimumSizes[target.tool.id] ?? .zero
                var changed = false

                if actual.width > requestedFrame.width + 1.5 {
                    let newWidth = max(learned.width, actual.width.rounded(.up))
                    if newWidth > learned.width + 0.5 {
                        learned.width = newWidth
                        changed = true
                    }
                }
                if actual.height > requestedFrame.height + 1.5 {
                    let newHeight = max(learned.height, actual.height.rounded(.up))
                    if newHeight > learned.height + 0.5 {
                        learned.height = newHeight
                        changed = true
                    }
                }

                if changed {
                    self.learnedMinimumSizes[target.tool.id] = learned
                    learnedSomething = true
                    NSLog(
                        "[ToolSwitchRail] Learned minimum for %@: %.0f x %.0f",
                        target.tool.name,
                        learned.width,
                        learned.height
                    )
                }
            }

            if learnedSomething {
                self.reconcileCanonicalFrameToLearnedMinimum(activeTool: activeTool, activeWindow: activeWindow)
            }
        }
    }

    private func reconcileCanonicalFrameToLearnedMinimum(activeTool: ToolItem, activeWindow: AXUIElement?) {
        guard var frame = canonicalStackFrame else { return }
        let minimum = compatibilityMinSize
        guard frame.width + 0.5 < minimum.width || frame.height + 0.5 < minimum.height else { return }

        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        let expanded = clampToCanonicalConstraints(frame)
        canonicalStackFrame = expanded

        if let activeWindow {
            setFrame(activeWindow, nsFrame: expanded)
        }

        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        railWindowController?.move(to: CGRect(
            x: expanded.minX - railWidth,
            y: expanded.minY,
            width: railWidth,
            height: expanded.height
        ))

        stackRegisteredWindows(onto: expanded, activeTool: activeTool, activeWindow: activeWindow, verify: false)
        if let activeWindow {
            AXUIElementPerformAction(activeWindow, kAXRaiseAction as CFString)
        }
    }

    private func bringWindowToFront(_ window: AXUIElement, app: NSRunningApplication, forceActivate: Bool = true) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if forceActivate {
            activateApp(app)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func workspaceSlot(preferred: CGRect?, fallback: CGRect?) -> CGRect {
        let minSize = compatibilityMinSize
        var slot: CGRect
        if let preferred, preferred.width > 100, preferred.height > 100 {
            slot = preferred
        } else if let fallback, fallback.width > 100, fallback.height > 100 {
            slot = fallback
        } else {
            slot = workspaceGeometry().content
        }

        if slot.width < minSize.width {
            slot.size.width = minSize.width
        }
        if slot.height < minSize.height {
            slot.size.height = minSize.height
        }
        return slot
    }

    private func framesAlmostEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 &&
        abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 &&
        abs(a.height - b.height) < 0.5
    }

    private func setAppHidden(_ app: NSRunningApplication, _ hidden: Bool) {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if hidden {
            if !app.isHidden {
                app.hide()
            }
        } else {
            if app.isHidden {
                app.unhide()
            }
        }
    }

    private func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    private func setFrame(_ window: AXUIElement, nsFrame: CGRect) {
        guard let current = windowFrame(window) else {
            let axFrame = convertToAXCoordinates(nsFrame)
            var pt = CGPoint(x: axFrame.minX, y: axFrame.minY)
            var sz = CGSize(width: axFrame.width, height: axFrame.height)
            if let pVal = AXValueCreate(.cgPoint, &pt) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pVal)
            }
            if let sVal = AXValueCreate(.cgSize, &sz) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sVal)
            }
            return
        }

        let posChanged = abs(current.minX - nsFrame.minX) >= 1 || abs(current.minY - nsFrame.minY) >= 1
        let sizeChanged = abs(current.width - nsFrame.width) >= 1 || abs(current.height - nsFrame.height) >= 1

        guard posChanged || sizeChanged else { return }

        let axFrame = convertToAXCoordinates(nsFrame)
        var point = CGPoint(x: axFrame.minX, y: axFrame.minY)
        var size = CGSize(width: axFrame.width, height: axFrame.height)

        let pointValue = AXValueCreate(.cgPoint, &point)
        let sizeValue = AXValueCreate(.cgSize, &size)

        if !sizeChanged {
            // Only position changed (origin shift / drag align): 1 single AX call, zero DOM reflow or GPU reallocation
            if let pointValue {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            }
            return
        }

        if !posChanged {
            // Only size changed
            if let sizeValue {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            return
        }

        // Both changed: order wisely to prevent screen-boundary clamping without redundant calls
        if nsFrame.width <= current.width && nsFrame.height <= current.height {
            // Shrinking: size first, then position
            if let sizeValue {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            if let pointValue {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            }
        } else {
            // Growing or moving left/up: position first, then size
            if let pointValue {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            }
            if let sizeValue {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
        }
    }

    func windowFrame(_ window: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posAX = posVal, let sizeAX = sizeVal else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        if CFGetTypeID(posAX) == AXValueGetTypeID() {
            AXValueGetValue(posAX as! AXValue, .cgPoint, &pt)
        }
        if CFGetTypeID(sizeAX) == AXValueGetTypeID() {
            AXValueGetValue(sizeAX as! AXValue, .cgSize, &sz)
        }
        guard sz.width > 50 && sz.height > 50 else { return nil }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        return CGRect(x: pt.x, y: primaryHeight - pt.y - sz.height, width: sz.width, height: sz.height)
    }

    private func convertToAXCoordinates(_ nsFrame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else {
            return nsFrame
        }
        let y = primary.frame.height - nsFrame.maxY
        return CGRect(x: nsFrame.minX, y: y, width: nsFrame.width, height: nsFrame.height)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    // MARK: - WindowTrackerDelegate

    func windowTracker(_ tracker: WindowTracker, didUpdateTargetFrame targetFrame: CGRect, railFrame: CGRect) {
        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetFrame) }) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let minAllowedTargetX = visible.minX + railWidth

        if isMaximized {
            let unifiedContentFrame = CGRect(
                x: visible.minX + railWidth,
                y: visible.minY,
                width: visible.width - railWidth,
                height: visible.height
            )
            let unifiedRailFrame = CGRect(
                x: visible.minX,
                y: visible.minY,
                width: railWidth,
                height: visible.height
            )

            if !tracker.isMouseDragging, let targetWindow = tracker.currentWindow,
               (abs(targetFrame.minX - unifiedContentFrame.minX) > 2 || abs(targetFrame.width - unifiedContentFrame.width) > 2) {
                setFrame(targetWindow, nsFrame: unifiedContentFrame)
            }
            activeContentFrame = unifiedContentFrame
            railWindowController?.move(to: unifiedRailFrame)
            return
        }

        // Prevent rail from being pushed off-screen to the left during drag
        if targetFrame.minX < minAllowedTargetX {
            let adjustedRailFrame = CGRect(
                x: visible.minX,
                y: targetFrame.minY,
                width: railWidth,
                height: targetFrame.height
            )
            railWindowController?.move(to: adjustedRailFrame)
        } else {
            railWindowController?.move(to: railFrame)
        }

        // The rail always follows the live window. The workspace frame used for the NEXT
        // switch is only learned from user gestures (mouse drag/resize, finalised in
        // windowTrackerDidSettle). An app restoring its own saved frame must not silently
        // redefine where every other tool is placed.
        if tracker.isMouseDragging {
            canonicalStackFrame = targetFrame
        }

        // Keep every already-visible sibling under the foreground window while the
        // user moves/resizes the active app. This removes the old-position "ghost".
        if tracker.isMouseDragging, tracker.lastUpdateChangedGeometry,
           let tool = tracker.currentTool,
           let target = tracker.currentWindow {
            liveSyncBackgroundWindows(to: targetFrame, activeTool: tool, activeWindow: target)
        }
    }

    func windowTrackerDidMinimizeTarget(_ tracker: WindowTracker) {
        if isMinimized { return }
        minimizeAll()
    }

    func windowTrackerDidSettle(_ tracker: WindowTracker) {
        orderAdjacentToTargetWindow()

        guard let targetWindow = tracker.currentWindow, let currentFrame = canonicalStackFrame else { return }

        let railWidth = CGFloat(configStore.configuration.workspace.railWidth)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(currentFrame) }) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        let clampedFrame: CGRect
        if isMaximized {
            clampedFrame = CGRect(
                x: visible.minX + railWidth,
                y: visible.minY,
                width: visible.width - railWidth,
                height: visible.height
            )
        } else {
            clampedFrame = clampToCanonicalConstraints(currentFrame)
        }
        canonicalStackFrame = clampedFrame

        let currentActual = windowFrame(targetWindow)
        if currentActual == nil || !framesAlmostEqual(currentActual!, clampedFrame) {
            setFrame(targetWindow, nsFrame: clampedFrame)
        }

        let adjustedRailFrame = CGRect(
            x: clampedFrame.minX - railWidth,
            y: clampedFrame.minY,
            width: railWidth,
            height: clampedFrame.height
        )
        railWindowController?.move(to: adjustedRailFrame)

        // Final exact synchronization + runtime minimum-size verification.
        if let tool = tracker.currentTool {
            stackRegisteredWindows(onto: clampedFrame, activeTool: tool, activeWindow: targetWindow, verify: true)
        }

        // Re-affirm foreground target window is at the top
        AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        railWindowController?.setFloatingForManagedTool(true)
        orderAdjacentToTargetWindow()
        lastLiveStackFrame = nil
    }

    func windowTrackerDidDeminimizeTarget(_ tracker: WindowTracker) {
        if isMinimized { return }
        railWindowController?.show()
        if let target = tracker.currentWindow {
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            orderAdjacentToTargetWindow()
        }
    }

    func windowTrackerDidDestroyTarget(_ tracker: WindowTracker) {
        if isMinimized { return }
        tracker.stopTracking(keepLastFrame: true)
        railWindowController?.show()
        attachToActiveToolIfAvailable()
    }
}

private struct WindowMatch {
    let app: NSRunningApplication
    let window: AXUIElement
}

enum RailError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        }
    }
}
