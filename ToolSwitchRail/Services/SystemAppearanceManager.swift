import AppKit
import Combine

final class SystemAppearanceManager: ObservableObject {
    static let shared = SystemAppearanceManager()

    @Published var isDarkMode: Bool = false

    private typealias SLSGetThemeFunc = @convention(c) () -> Bool
    private typealias SLSSetThemeNotifyingFunc = @convention(c) (Bool, Bool) -> Void

    private var slsGetTheme: SLSGetThemeFunc?
    private var slsSetThemeNotifying: SLSSetThemeNotifyingFunc?

    private init() {
        initSkyLight()
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

    private func initSkyLight() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) {
            if let getSym = dlsym(handle, "SLSGetAppearanceThemeLegacy") {
                slsGetTheme = unsafeBitCast(getSym, to: SLSGetThemeFunc.self)
            }
            if let setSym = dlsym(handle, "SLSSetAppearanceThemeNotifying") {
                slsSetThemeNotifying = unsafeBitCast(setSym, to: SLSSetThemeNotifyingFunc.self)
            }
        }
    }

    func updateCurrentStatus() {
        let dark: Bool
        if let getTheme = slsGetTheme {
            dark = getTheme()
        } else {
            let style = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleInterfaceStyle"] as? String
            dark = (style == "Dark")
        }
        if self.isDarkMode != dark {
            self.isDarkMode = dark
        }
    }

    func toggleSystemAppearance() {
        setSystemDarkMode(!isDarkMode)
    }

    func setSystemDarkMode(_ dark: Bool) {
        self.isDarkMode = dark

        // 1. Preferred method: SkyLight WindowServer C API (0 permissions, zero latency)
        if let setTheme = slsSetThemeNotifying {
            setTheme(dark, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.updateCurrentStatus()
            }
            return
        }

        // 2. Fallback: AppleScript
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark ? "true" : "false")"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[ToolSwitchRail] Failed to set system dark mode via AppleScript: %@", error)
                }
            }
            DispatchQueue.main.async {
                self?.updateCurrentStatus()
            }
        }
    }
}
