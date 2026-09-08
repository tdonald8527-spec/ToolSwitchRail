import SwiftUI
import AppKit

struct ToolIconView: View {
    let tool: ToolItem
    let isSelected: Bool
    var isPressed: Bool = false
    var isHovered: Bool = false
    var isLaunching: Bool = false
    var isOpen: Bool = true
    var status: AgentTaskStatus = .unknown
    var usageText: String? = nil
    var namespace: Namespace.ID? = nil
    var onRemove: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            // Smooth background highlight
            if isSelected {
                if let namespace = namespace {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 0.8)
                        }
                        .matchedGeometryEffect(id: "activeToolBg", in: namespace)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.14), lineWidth: 0.8)
                        }
                }
            } else if isHovered {
                // Soft hover background
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .transition(.opacity)
            }

            // Smooth sliding indicator pill on the left edge with subtle glow
            if isSelected {
                if let namespace = namespace {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.9), Color.accentColor],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3.5, height: 18)
                        .offset(x: 2)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 3, x: 1, y: 0)
                        .matchedGeometryEffect(id: "activeToolPill", in: namespace)
                } else {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3.5, height: 18)
                        .offset(x: 2)
                }
            }

            // Tool Icon centered with soft press & launching animations
            HStack {
                Spacer()
                icon
                    .frame(width: 26, height: 26)
                    .scaleEffect(isLaunching ? 1.06 : 1.0)
                    .opacity(isLaunching ? 0.6 : 1.0)
                    .animation(
                        isLaunching
                            ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                            : .spring(response: 0.24, dampingFraction: 0.8),
                        value: isLaunching
                    )
                Spacer()
            }

            if isOpen {
                StatusDotView(status: status)
                    .offset(x: 30, y: 14)
            }
        }
        .frame(width: 44, height: 44)
        .opacity(isOpen || isSelected || isLaunching ? 1.0 : 0.34)
        .scaleEffect(isPressed ? 0.94 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isPressed)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .help(tooltipText)
        .contextMenu {
            Button {
                onActivate?()
            } label: {
                Label("切换至 \(tool.name)", systemImage: "arrow.up.forward.app")
            }
            Divider()
            Button(role: .destructive) {
                onRemove?()
            } label: {
                Label("从 Rail 移除", systemImage: "trash")
            }
        }
    }

    private var tooltipText: String {
        var parts = [tool.name]
        parts.append(isOpen ? "运行中" : "已关闭")
        parts.append(status.shortLabel)
        if let usageText, !usageText.isEmpty {
            parts.append(usageText)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var icon: some View {
        if let image = ToolIconProvider.image(for: tool) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else if let symbol = tool.symbolName, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.primary.opacity(isSelected ? 0.95 : 0.72))
        } else {
            Text(String(tool.name.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(.primary.opacity(isSelected ? 0.95 : 0.72))
        }
    }
}

struct StatusDotView: View {
    let status: AgentTaskStatus

    var body: some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.6)
            )
            .opacity(status == .working ? 1.0 : 0.95)
            .scaleEffect(status == .working ? 1.08 : 1.0)
            .animation(
                status == .working
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: status
            )
            .accessibilityLabel(status.shortLabel)
    }
}

enum ToolIconProvider {
    private static var iconCache: [String: NSImage] = [:]

    static func image(for tool: ToolItem) -> NSImage? {
        if let cached = iconCache[tool.id] {
            return cached
        }
        let img = loadIcon(for: tool)
        if let img {
            iconCache[tool.id] = img
        }
        return img
    }

    private static func loadIcon(for tool: ToolItem) -> NSImage? {
        // 1. Explicit iconPath (supports ~ tilde expansion)
        if let path = tool.iconPath, !path.isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded),
               let img = NSImage(contentsOfFile: expanded) {
                return img
            }
        }

        // 2. Bundled resource in App Contents/Resources (e.g. icons/chatgpt-web.png or chatgpt-web.png)
        if let bundledURL = Bundle.main.url(forResource: tool.id, withExtension: "png")
            ?? Bundle.main.url(forResource: tool.id, withExtension: "png", subdirectory: "icons") {
            if let img = NSImage(contentsOf: bundledURL) {
                return img
            }
        }

        // 3. User Application Support icons directory (~/Library/Application Support/ToolSwitchRail/icons/<id>.png)
        let appSupportIcon = NSString(string: "~/Library/Application Support/ToolSwitchRail/icons/\(tool.id).png").expandingTildeInPath
        if FileManager.default.fileExists(atPath: appSupportIcon),
           let img = NSImage(contentsOfFile: appSupportIcon) {
            return img
        }

        // 4. Native app bundle ID
        if let bundleID = tool.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        // 5. Native app name
        if let appName = tool.appName {
            let candidates = [
                "/Applications/\(appName).app",
                NSString(string: "~/Applications/\(appName).app").expandingTildeInPath
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        // 6. User applications directory for web app wrappers or shortcuts
        // IMPORTANT: Web tools must not fall back to native /Applications apps of the same name
        let nameCandidates: [String]
        if tool.kind == .web {
            nameCandidates = [
                NSString(string: "~/Applications/\(tool.name).app").expandingTildeInPath,
                NSString(string: "~/Applications/Chrome Apps.localized/\(tool.name).app").expandingTildeInPath
            ]
        } else {
            nameCandidates = [
                "/Applications/\(tool.name).app",
                NSString(string: "~/Applications/\(tool.name).app").expandingTildeInPath,
                NSString(string: "~/Applications/Chrome Apps.localized/\(tool.name).app").expandingTildeInPath
            ]
        }
        for path in nameCandidates where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        return nil
    }
}
