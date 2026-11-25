import SwiftUI
import AppKit

struct DashboardToolCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// Menu-bar dashboard: see what is running, switch with one click, add an app.
/// Everything else (collapse, window size, remove, config, quit) lives in the one
/// settings menu, reachable from the gear here, the rail gear, or right-clicking the
/// menu-bar icon.
struct StatusBarDashboardView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var statusMonitor: ToolStatusMonitor
    @ObservedObject private var systemAppearance = SystemAppearanceManager.shared

    var onClose: () -> Void

    private var isLightMode: Bool { !systemAppearance.isDarkMode }
    private var cardBackground: Color { isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06) }
    private var cardBorder: Color { isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.1) }
    private var tools: [ToolItem] { configStore.configuration.tools.filter(\.enabled) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if !AccessibilityPermission.isTrusted {
                permissionBanner
                Divider().opacity(0.5)
            }

            if tools.isEmpty {
                emptyState
            } else {
                toolGrid
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .animation(Motion.standard, value: tools.map(\.id))
        .animation(Motion.standard, value: windowManager.selectedToolID)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            Text("Tool Switch Rail")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                onClose()
                windowManager.showSettingsMenu()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailPressStyle())
            .help("设置")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("需要辅助功能权限才能对齐窗口")
                .font(.system(size: 12))
            Spacer()
            Button("去设置") {
                onClose()
                RailActions.openAccessibilitySettings()
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Rail 上还没有应用")
                .font(.system(size: 12, weight: .medium))
            Text("点下方「添加应用」，选一个常用的 AI 应用")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var toolGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tools) { tool in
                    toolCard(tool)
                        .transition(Motion.appear)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: CGFloat(max(1, min(4, (tools.count + 1) / 2))) * 60 + 12)
    }

    private func toolCard(_ tool: ToolItem) -> some View {
        let isOpen = windowManager.openToolIDs.contains(tool.id)
        let isSelected = windowManager.selectedToolID == tool.id
        let isLaunching = windowManager.launchingToolID == tool.id
        let state = ToolStateLabel.text(isLaunching: isLaunching, isSelected: isSelected, isOpen: isOpen)
        let isCurrent = state == "当前"

        return Button {
            onClose()
            windowManager.switchTo(tool)
        } label: {
            HStack(spacing: 8) {
                iconView(for: tool)
                    .opacity(isOpen || isLaunching ? 1.0 : 0.45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ToolStateLabel.color(isLaunching: isLaunching, isSelected: isSelected, isOpen: isOpen))
                            .frame(width: 6, height: 6)
                        Text(state)
                            .font(.system(size: 10.5))
                            .foregroundColor(isCurrent ? .accentColor : .secondary)
                            .contentTransition(.opacity)
                    }
                    .animation(Motion.fade, value: state)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(isLightMode ? 0.08 : 0.16) : cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isCurrent ? Color.accentColor.opacity(0.45) : cardBorder, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardToolCardButtonStyle())
        .help("\(tool.name) · \(state)")
        .accessibilityLabel("\(tool.name) · \(state)")
        .contextMenu {
            Button {
                onClose()
                windowManager.switchTo(tool)
            } label: {
                Label("切换到 \(tool.name)", systemImage: "arrow.up.forward.app")
            }
            Divider()
            Button(role: .destructive) {
                RailActions.removeTool(id: tool.id, configStore: configStore)
            } label: {
                Label("从 Rail 移除", systemImage: "minus.circle")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                RailActions.addApp(configStore: configStore, windowManager: windowManager) { onClose() }
            } label: {
                Label("添加应用", systemImage: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailPressStyle())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func iconView(for tool: ToolItem) -> some View {
        if let image = ToolIconProvider.image(for: tool) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
        } else if let symbol = tool.symbolName, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundColor(.primary)
        } else {
            Text(String(tool.name.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 28, height: 28)
                .foregroundColor(.primary)
        }
    }
}
