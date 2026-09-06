import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configStore: ConfigStore!
    private var windowManager: WindowManager!
    private var statusMonitor: ToolStatusMonitor!
    private var railWindowController: RailWindowController!
    private var hotKeyManager: GlobalHotKeyManager!
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
                self.railWindowController.applyAppearance(for: nil)
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
            menu.addItem(item)
        }

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
