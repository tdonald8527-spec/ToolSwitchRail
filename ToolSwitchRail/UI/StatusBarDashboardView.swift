import SwiftUI
import AppKit

struct DashboardToolCardButtonStyle: ButtonStyle {
    var isLightMode: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
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

            // MARK: - Agent Cards List (2-Column Compact Grid)
            let columns = [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ]
            let tools = configStore.configuration.tools.filter(\.enabled)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 8) {
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
                            HStack(spacing: 7) {
                                // App Icon View
                                iconView(for: tool)

                                // Tool Info
                                VStack(alignment: .leading, spacing: 1.5) {
                                    HStack(spacing: 3) {
                                        Text(tool.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)

                                        Spacer(minLength: 0)

                                        Circle()
                                            .fill(snap.status.needsYou ? Color.orange : (snap.status == .working ? Color(red: 0.20, green: 0.72, blue: 0.45) : (isOpen ? Color.green : Color.secondary.opacity(0.35))))
                                            .frame(width: 6, height: 6)
                                    }

                                    HStack(spacing: 3) {
                                        if snap.status.needsYou {
                                            Text("需确认")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundColor(.orange)
                                        } else if snap.status == .working {
                                            Text("工作中")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundColor(Color(red: 0.20, green: 0.72, blue: 0.45))
                                        } else if isSelected {
                                            Text("当前聚焦")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundColor(.accentColor)
                                        } else if isOpen {
                                            Text("就绪在线")
                                                .font(.system(size: 9.5))
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text("就绪")
                                                .font(.system(size: 9.5))
                                                .foregroundColor(.secondary.opacity(0.7))
                                        }

                                        if let task = snap.taskTitle, !task.isEmpty {
                                            Text("· \(task)")
                                                .font(.system(size: 9.5))
                                                .foregroundColor(.secondary.opacity(0.75))
                                                .lineLimit(1)
                                        } else if let usage = snap.usageText, !usage.isEmpty {
                                            Text("· \(usage)")
                                                .font(.system(size: 9.5))
                                                .foregroundColor(.secondary.opacity(0.7))
                                                .lineLimit(1)
                                        }
                                    }
                                    .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? (isLightMode ? Color.accentColor.opacity(0.08) : Color.accentColor.opacity(0.16)) : cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : cardBorder, lineWidth: 0.8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DashboardToolCardButtonStyle(isLightMode: isLightMode))
                        .contextMenu {
                            Button {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                    windowManager.switchTo(tool)
                                    onClose()
                                }
                            } label: {
                                Label("切换至 \(tool.name)", systemImage: "arrow.up.forward.app")
                            }
                            Divider()
                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                    configStore.removeTool(id: tool.id)
                                }
                            } label: {
                                Label("从 Rail 移除 \(tool.name)", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)

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

                Menu {
                    ForEach(configStore.configuration.tools) { tool in
                        Button(role: .destructive) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                configStore.removeTool(id: tool.id)
                            }
                        } label: {
                            Label("移除 \(tool.name)", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("移除应用", systemImage: "minus")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)

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
                .frame(width: 22, height: 22)
        } else if let symbol = tool.symbolName, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                .foregroundColor(.primary)
        } else {
            Text(String(tool.name.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 22, height: 22)
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
