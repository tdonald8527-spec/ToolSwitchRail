import AppKit
import ApplicationServices

struct AccessibilityPermission {
    static var isTrusted: Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func promptIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "Tool Switch Rail 需要“辅助功能”权限以实现无缝贴合与实时跟随。\n\n⚠️ 重要提示：\n如果“系统设置”的列表中已开启了 Tool Switch Rail，请将其先关闭再重新开启（或选中后点击下方减号删除，再重新添加）。因为应用更新签名后，macOS 需要重新激活授权。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "我知道了")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
