import AppKit
import Combine
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
                self?.updateStatusItemMenu()
                guard let self else { return }
                let geometry = self.windowManager.workspaceGeometry()
                self.railWindowController.move(to: geometry.rail)
                self.railWindowController.applyAppearance(for: self.windowManager.activeTool)
            }
            .store(in: &cancellables)

        statusMonitor.$quotaReports
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemMenu()
            }
            .store(in: &cancellables)

        AccessibilityPermission.promptIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowManager.restoreCurrent()
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Tool Switch Rail")
            button.image?.isTemplate = true
        }
        updateStatusItemMenu()
    }

    private func updateStatusItemMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "显示 / 最小化", action: #selector(toggleMinimizeAction), keyEquivalent: "m")
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)

        // MARK: - Agent Quota & Status Section
        let reports = statusMonitor.quotaReports
        if !reports.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "桌面 Agent 额度与状态", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for report in reports {
                let item = NSMenuItem(title: "  \(report.title): \(report.detail)", action: nil, keyEquivalent: "")
                if !report.subDetails.isEmpty {
                    let subMenu = NSMenu()
                    let subHeader = NSMenuItem(title: report.detail, action: nil, keyEquivalent: "")
                    subHeader.isEnabled = false
                    subMenu.addItem(subHeader)
                    subMenu.addItem(NSMenuItem.separator())
                    for sub in report.subDetails {
                        let subItem = NSMenuItem(title: sub, action: nil, keyEquivalent: "")
                        subItem.isEnabled = false
                        subMenu.addItem(subItem)
                    }
                    item.submenu = subMenu
                    item.isEnabled = true
                } else {
                    item.isEnabled = false
                }
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let tools = configStore.configuration.tools.filter(\.enabled)
        for (idx, tool) in tools.enumerated() {
            let keyEquivalent = (idx < 9) ? "\(idx + 1)" : ""
            let item = NSMenuItem(title: tool.name, action: #selector(selectToolAction(_:)), keyEquivalent: keyEquivalent)
            if !keyEquivalent.isEmpty {
                item.keyEquivalentModifierMask = [.command, .option]
            }
            item.target = self
            item.representedObject = tool

            let toolMenu = NSMenu()
            let switchItem = NSMenuItem(title: "切换至 \(tool.name)", action: #selector(selectToolAction(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.representedObject = tool
            toolMenu.addItem(switchItem)

            toolMenu.addItem(NSMenuItem.separator())

            let removeItem = NSMenuItem(title: "从 Rail 移除", action: #selector(removeToolAction(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = tool
            toolMenu.addItem(removeItem)

            item.submenu = toolMenu
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // MARK: - Add App & Appearance Controls
        let addItem = NSMenuItem(title: "添加应用...", action: #selector(addAppAction), keyEquivalent: "")
        addItem.target = self
        menu.addItem(addItem)

        let appearanceItem = NSMenuItem(title: "外观模式", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        let currentMode = configStore.configuration.workspace.appearance

        let systemItem = NSMenuItem(title: "跟随应用 / 系统", action: #selector(setAppearanceSystem), keyEquivalent: "")
        systemItem.target = self
        systemItem.state = (currentMode == .system) ? .on : .off
        appearanceMenu.addItem(systemItem)

        let darkItem = NSMenuItem(title: "深色模式", action: #selector(setAppearanceDark), keyEquivalent: "")
        darkItem.target = self
        darkItem.state = (currentMode == .dark) ? .on : .off
        appearanceMenu.addItem(darkItem)

        let lightItem = NSMenuItem(title: "浅色模式", action: #selector(setAppearanceLight), keyEquivalent: "")
        lightItem.target = self
        lightItem.state = (currentMode == .light) ? .on : .off
        appearanceMenu.addItem(lightItem)

        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        menu.addItem(NSMenuItem.separator())

        let configItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfigAction), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let reloadItem = NSMenuItem(title: "重新载入配置", action: #selector(reloadConfigAction), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 Tool Switch Rail", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
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

    @objc private func setAppearanceSystem() {
        configStore.setAppearance(.system)
    }

    @objc private func setAppearanceDark() {
        configStore.setAppearance(.dark)
    }

    @objc private func setAppearanceLight() {
        configStore.setAppearance(.light)
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
