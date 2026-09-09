import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore!
    private var windowManager: WindowManager!
    private var statusMonitor: ToolStatusMonitor!
    private var railWindowController: RailWindowController!
    private var hotKeyManager: GlobalHotKeyManager!
    private var dragIsolationCoordinator: DragIsolationCoordinator!
    private var railAdjacencyCoordinator: RailAdjacencyCoordinator!
    private var cancellables = Set<AnyCancellable>()

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configStore = ConfigStore()
        windowManager = WindowManager(configStore: configStore)
        statusMonitor = ToolStatusMonitor(configStore: configStore)
        hotKeyManager = GlobalHotKeyManager()

        railWindowController = RailWindowController(
            configStore: configStore,
            windowManager: windowManager,
            statusMonitor: statusMonitor
        ) { [weak self] tool in
            self?.windowManager.switchTo(tool)
        }
        windowManager.railWindowController = railWindowController

        let geometry = windowManager.workspaceGeometry()
        railWindowController.move(to: geometry.rail)
        railWindowController.showWindow(nil)
        railWindowController.window?.orderFrontRegardless()

        windowManager.attachToActiveToolIfAvailable()

        // Keep background native managed apps out of the live drag/resize hot path.
        // The coordinator only activates after it detects a real workspace geometry change.
        dragIsolationCoordinator = DragIsolationCoordinator(
            configStore: configStore,
            windowManager: windowManager
        )

        // Enforce the hard seam invariant even when a third-party app re-zooms or
        // restores itself to the screen's left edge after Tool Switch Rail placed it.
        railAdjacencyCoordinator = RailAdjacencyCoordinator(
            configStore: configStore,
            windowManager: windowManager,
            railWindowController: railWindowController
        )

        NSLog("[ToolSwitchRail] App launched, AXTrusted: %d, railFrame: %@", AccessibilityPermission.isTrusted ? 1 : 0, NSStringFromRect(geometry.rail))

        setupStatusItem()
        registerHotKeys()

        configStore.$configuration
            .dropFirst()
            .sink { [weak self] _ in
                self?.registerHotKeys()
                guard let self else { return }
                let geometry = self.windowManager.workspaceGeometry()
                self.railWindowController.move(to: geometry.rail)
                self.railWindowController.applyAppearance(for: self.windowManager.activeTool)
            }
            .store(in: &cancellables)

        SystemAppearanceManager.shared.$isDarkMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.railWindowController.applyAppearance(for: self.windowManager.activeTool)
            }
            .store(in: &cancellables)

        AccessibilityPermission.promptIfNeeded()

        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("app.toolswitchrail.mac.ToggleDashboard"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.statusItemClicked(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowManager.restoreCurrent()
        return true
    }

    private var popover: NSPopover?

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Tool Switch Rail")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let dashboard = StatusBarDashboardView(
            configStore: configStore,
            windowManager: windowManager,
            statusMonitor: statusMonitor,
            onClose: { [weak self] in
                self?.popover?.performClose(nil)
            }
        )
        pop.contentViewController = NSHostingController(rootView: dashboard)
        self.popover = pop
    }

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        let isRightClick = (NSApp.currentEvent?.type == .rightMouseUp)

        if isRightClick {
            popover?.performClose(nil)
            showQuickContextMenu(for: button)
            return
        }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showQuickContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "显示 / 最小化 Rail", action: #selector(toggleMinimizeAction), keyEquivalent: "m")
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let isDark = SystemAppearanceManager.shared.isDarkMode
        let appearanceItem = NSMenuItem(
            title: isDark ? "切换为系统浅色模式" : "切换为系统深色模式",
            action: #selector(toggleSystemAppearanceAction),
            keyEquivalent: ""
        )
        appearanceItem.target = self
        menu.addItem(appearanceItem)

        menu.addItem(NSMenuItem.separator())

        let openConfig = NSMenuItem(title: "打开配置文件", action: #selector(openConfigAction), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reloadConfig = NSMenuItem(title: "重新载入配置", action: #selector(reloadConfigAction), keyEquivalent: "")
        reloadConfig.target = self
        menu.addItem(reloadConfig)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Tool Switch Rail", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleMinimizeAction() {
        windowManager.toggleMinimize()
    }

    @objc private func selectToolAction(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? ToolItem else { return }
        windowManager.switchTo(tool)
    }

    @objc private func addAppAction() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加至 Rail"
        panel.message = "请选择要添加到 Tool Switch Rail 的应用程序 (.app)"
        if panel.runModal() == .OK, let url = panel.url {
            if let tool = configStore.addTool(fromAppURL: url) {
                windowManager.switchTo(tool)
            }
        }
    }

    @objc private func removeToolAction(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? ToolItem else { return }
        configStore.removeTool(id: tool.id)
    }

    @objc private func toggleSystemAppearanceAction() {
        SystemAppearanceManager.shared.toggleSystemAppearance()
        configStore.setAppearance(.system)
    }

    @objc private func setSystemAppearanceDark() {
        SystemAppearanceManager.shared.setSystemDarkMode(true)
        configStore.setAppearance(.system)
    }

    @objc private func setSystemAppearanceLight() {
        SystemAppearanceManager.shared.setSystemDarkMode(false)
        configStore.setAppearance(.system)
    }

    @objc private func openConfigAction() {
        configStore.openConfigFile()
    }

    @objc private func reloadConfigAction() {
        configStore.reload()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func registerHotKeys() {
        let tools = configStore.configuration.tools.filter(\.enabled)
        hotKeyManager.register(count: min(9, max(tools.count, 9)))
        NSLog("[ToolSwitchRail] Registered hotkeys count: %ld", min(9, max(tools.count, 9)))

        hotKeyManager.onMinimizeHotKey = { [weak self] in
            Task { @MainActor in
                self?.windowManager.toggleMinimize()
            }
        }

        hotKeyManager.onHotKey = { [weak self] index in
            Task { @MainActor in
                guard let self else { return }
                let current = self.configStore.configuration.tools.filter(\.enabled)
                let number = index + 1
                NSLog("[ToolSwitchRail] Hotkey triggered: Cmd+Opt+%ld", number)
                if let explicitMatch = current.first(where: { $0.hotkeyIndex == number }) {
                    self.windowManager.switchTo(explicitMatch)
                    return
                }
                guard current.indices.contains(index) else { return }
                self.windowManager.switchTo(current[index])
            }
        }
    }
}
