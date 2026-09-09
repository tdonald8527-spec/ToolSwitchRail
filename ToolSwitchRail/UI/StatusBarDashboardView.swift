import SwiftUI
import AppKit

struct DashboardToolRowButtonStyle: ButtonStyle {
    var isLightMode: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? (isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12)) : Color.clear)
            )
    }
}

struct StatusBarDashboardView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var statusMonitor: ToolStatusMonitor
    @ObservedObject private var systemAppearance = SystemAppearanceManager.shared

    var onClose: () -> Void

    private var isLightMode: Bool {
        !systemAppearance.isDarkMode
    }

    private var cardBackground: Color {
        isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06)
    }

    private var cardBorder: Color {
        isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Switch Rail")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("桌面 Agent 侧边栏工作台")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("关闭面板")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.5)

            // MARK: - Quick Action Control Cards
            HStack(spacing: 10) {
                // System Dark / Light Mode Toggle Card
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        systemAppearance.toggleSystemAppearance()
                    }
                } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(systemAppearance.isDarkMode ? Color.indigo.opacity(0.2) : Color.orange.opacity(0.2))
                                .frame(width: 26, height: 26)
                            Image(systemName: systemAppearance.isDarkMode ? "moon.stars.fill" : "sun.max.fill")
                                .font(.system(size: 13))
                                .foregroundColor(systemAppearance.isDarkMode ? .indigo : .orange)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("系统外观")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                            Text(systemAppearance.isDarkMode ? "深色模式" : "浅色模式")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(cardBorder, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)

                // Rail Toggle Card
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        windowManager.toggleMinimize()
                    }
                } label: {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(width: 26, height: 26)
                            Image(systemName: "rectangle.righthalf.inset.filled")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("侧边栏")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                            Text("显示 / 最小化")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(cardBorder, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .opacity(0.5)

            // MARK: - Agent Status Section Header
            HStack {
                Text("桌面 Agent 运行看板")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(configStore.configuration.tools.filter(\.enabled).count) 个已配置")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // MARK: - Agent Cards List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    let tools = configStore.configuration.tools.filter(\.enabled)
                    ForEach(tools) { tool in
                        let isOpen = windowManager.openToolIDs.contains(tool.id)
                        let isSelected = windowManager.selectedToolID == tool.id
                        let snap = statusMonitor.snapshot(for: tool.id)

                        Button {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                windowManager.switchTo(tool)
                                onClose()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                // App Icon View
                                iconView(for: tool)

                                // Tool Info
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(tool.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.primary)

                                        if isSelected {
                                            Text("当前聚焦")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundColor(.accentColor)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        }
                                    }

                                    if let usage = snap.usageText, !usage.isEmpty {
                                        Text(usage)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text(tool.appName ?? tool.name)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                // Live Status Badge
                                if snap.status.needsYou {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                                        Text("需确认")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.orange)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                                } else if isOpen {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                        Text("运行中")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12), in: Capsule())
                                } else {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                                        Text("就绪")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DashboardToolRowButtonStyle(isLightMode: isLightMode))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 270)

            Divider()
                .opacity(0.5)

            // MARK: - Footer Actions
            HStack(spacing: 8) {
                Button {
                    selectAndAddApp()
                } label: {
                    Label("添加应用", systemImage: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    configStore.openConfigFile()
                    onClose()
                } label: {
                    Label("配置", systemImage: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    configStore.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新载入配置")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("退出 Tool Switch Rail")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isLightMode ? Color.black.opacity(0.02) : Color.white.opacity(0.02))
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func iconView(for tool: ToolItem) -> some View {
        if let image = ToolIconProvider.image(for: tool) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else if let symbol = tool.symbolName, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 24, height: 24)
                .foregroundColor(.primary)
        } else {
            Text(String(tool.name.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 24, height: 24)
                .foregroundColor(.primary)
        }
    }

    private func selectAndAddApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加至 Rail"
        panel.message = "请选择要添加到 Tool Switch Rail 的应用程序 (.app)"
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                if let tool = configStore.addTool(fromAppURL: url) {
                    windowManager.switchTo(tool)
                    onClose()
                }
            }
        }
    }
}
