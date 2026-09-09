import AppKit
import Combine

final class SystemAppearanceManager: ObservableObject {
    static let shared = SystemAppearanceManager()

    @Published var isDarkMode: Bool = false

    private init() {
        updateCurrentStatus()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateCurrentStatus()
            }
        }
    }

    func updateCurrentStatus() {
        let style = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleInterfaceStyle"] as? String
        let dark = (style == "Dark")
        if self.isDarkMode != dark {
            self.isDarkMode = dark
        }
    }

    func toggleSystemAppearance() {
        setSystemDarkMode(!isDarkMode)
    }

    func setSystemDarkMode(_ dark: Bool) {
        self.isDarkMode = dark
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark ? "true" : "false")"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[ToolSwitchRail] Failed to set system dark mode: %@", error)
                }
            }
            DispatchQueue.main.async {
                self?.updateCurrentStatus()
            }
        }
    }
}
