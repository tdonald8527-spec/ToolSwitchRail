import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RailView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var statusMonitor: ToolStatusMonitor
    @ObservedObject private var systemAppearance = SystemAppearanceManager.shared
    let onSelect: (ToolItem) -> Void
    @StateObject private var reorderManager = ToolReorderManager()
    @Namespace private var railNamespace

    private var railWidth: CGFloat {
        CGFloat(configStore.configuration.workspace.railWidth)
    }

    private var tools: [ToolItem] {
        configStore.configuration.tools.filter(\.enabled)
    }

    private var currentTool: ToolItem? {
        windowManager.activeTool
    }

    private var currentAppearance: AppearanceMode {
        configStore.configuration.workspace.appearance
    }

    private var isEffectiveLightMode: Bool {
        switch currentAppearance {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            return !systemAppearance.isDarkMode
        }
    }

    private var currentBackgroundColor: Color {
        if let tool = currentTool {
            return Color(hex: tool.resolvedBackgroundColor(for: isEffectiveLightMode))
        }
        return isEffectiveLightMode ? Color(hex: "#F3F3F3") : Color(hex: "#1E1E1E")
    }

    private var controlForegroundColor: Color {
        isEffectiveLightMode ? Color(white: 0.15, opacity: 0.85) : Color(white: 0.95, opacity: 0.85)
    }

    private var dragHandleColor: Color {
        isEffectiveLightMode ? Color.black.opacity(0.22) : Color.white.opacity(0.25)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Adaptive Solid Background matching the active tool (fills full width including 16pt flange)
            currentBackgroundColor
                .ignoresSafeArea()
                .animation(Motion.fade, value: currentBackgroundColor)

            VStack(spacing: 6) {
                RailHeaderDragArea(windowManager: windowManager, isLightMode: isEffectiveLightMode)
                    .padding(.top, 10)

                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    let isBeingDragged = reorderManager.draggedToolID == tool.id
                    let itemOffset = reorderManager.visualOffset(for: tool.id, at: index)

                    ToolIconView(
                        tool: tool,
                        isSelected: windowManager.selectedToolID == tool.id,
                        isLightMode: isEffectiveLightMode,
                        isPressed: reorderManager.pressedToolID == tool.id,
                        isHovered: reorderManager.hoveredToolID == tool.id,
                        isLaunching: windowManager.launchingToolID == tool.id,
                        isOpen: windowManager.openToolIDs.contains(tool.id),
                        status: statusMonitor.snapshot(for: tool.id).status,
                        usageText: statusMonitor.snapshot(for: tool.id).usageText,
                        hasUnread: statusMonitor.unreadToolIDs.contains(tool.id),
                        namespace: railNamespace,
                        onRemove: {
                            RailActions.removeTool(id: tool.id, configStore: configStore)
                        },
                        onActivate: {
                            onSelect(tool)
                        }
                    )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isBeingDragged ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .scaleEffect(isBeingDragged ? 1.08 : 1.0)
                        .shadow(color: isBeingDragged ? Color.black.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
                        // Lift on pick-up / settle on drop, quickly; the dragged item itself tracks the pointer 1:1.
                        .animation(Motion.quick, value: isBeingDragged)
                        .offset(y: itemOffset)
                        .animation(isBeingDragged ? nil : Motion.standard, value: itemOffset)
                        .transition(Motion.appear)
                        .zIndex(isBeingDragged ? 100 : 0)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                if !reorderManager.isDragging {
                                    reorderManager.hoveredToolID = tool.id
                                }
                            } else {
                                if reorderManager.hoveredToolID == tool.id {
                                    reorderManager.hoveredToolID = nil
                                }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if reorderManager.pressedToolID != tool.id {
                                        reorderManager.pressedToolID = tool.id
                                    }
                                    let dy = value.translation.height
                                    if abs(dy) >= 6 || reorderManager.isDragging {
                                        if !reorderManager.isDragging {
                                            reorderManager.beginDrag(toolID: tool.id, index: index)
                                        }
                                        reorderManager.updateDrag(translationY: dy, totalCount: tools.count)
                                    }
                                }
                                .onEnded { value in
                                    reorderManager.pressedToolID = nil
                                    if reorderManager.isDragging {
                                        withAnimation(Motion.standard) {
                                            reorderManager.endDrag(tools: tools, configStore: configStore)
                                        }
                                    } else if abs(value.translation.width) < 12 && abs(value.translation.height) < 12 {
                                        onSelect(tool)
                                    }
                                }
                        )
                        .contextMenu {
                            Button {
                                onSelect(tool)
                            } label: {
                                Label("切换至 \(tool.name)", systemImage: "arrow.up.forward.app")
                            }
                            Divider()
                            Button(role: .destructive) {
                                RailActions.removeTool(id: tool.id, configStore: configStore)
                            } label: {
                                Label("从 Rail 移除", systemImage: "minus.circle")
                            }
                        }
                }

                Spacer(minLength: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                windowManager.handleRailDrag(translation: value.translation)
                            }
                            .onEnded { _ in
                                windowManager.endRailDrag()
                            }
                    )

                // Bottom controls: add an app, settings. (Appearance follows macOS automatically.)
                VStack(spacing: 2) {
                    RailControlButton(systemName: "plus", help: "添加应用", color: controlForegroundColor, isLightMode: isEffectiveLightMode) {
                        RailActions.addApp(configStore: configStore, windowManager: windowManager)
                    }
                    RailControlButton(systemName: "gearshape", help: "设置", color: controlForegroundColor, isLightMode: isEffectiveLightMode) {
                        windowManager.showSettingsMenu()
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isEffectiveLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isEffectiveLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                )

                Spacer().frame(height: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                windowManager.handleRailDrag(translation: value.translation)
                            }
                            .onEnded { _ in
                                windowManager.endRailDrag()
                            }
                    )
            }
            .frame(width: railWidth)
            .padding(.horizontal, 0)
            // Selection moves the highlight from the old icon to the new one; adding or
            // removing a tool lets the others slide into place.
            .animation(Motion.standard, value: windowManager.selectedToolID)
            .animation(Motion.standard, value: tools.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(isEffectiveLightMode ? .light : .dark)
    }

}

struct RailHeaderDragArea: View {
    @ObservedObject var windowManager: WindowManager
    var isLightMode: Bool = false

    var body: some View {
        VStack(spacing: 7) {
            // One clearly labelled action instead of window-style traffic lights:
            // it acts on the whole workspace, not on this strip.
            RailControlButton(
                systemName: "chevron.down",
                help: "收起工作区（⌥⌘M）",
                color: isLightMode ? Color(white: 0.15, opacity: 0.85) : Color(white: 0.95, opacity: 0.85),
                isLightMode: isLightMode
            ) {
                windowManager.minimizeCurrent()
            }

            // Drag handle: drag here to move the workspace.
            Capsule()
                .fill(isLightMode ? Color.black.opacity(0.20) : Color.white.opacity(0.22))
                .frame(width: 20, height: 3)
                .help("拖动以移动工作区")
        }
        .frame(width: 56, height: 46)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    windowManager.handleRailDrag(translation: value.translation)
                }
                .onEnded { _ in
                    windowManager.endRailDrag()
                }
        )
    }
}

/// Small rail control: press feedback, hover highlight, tooltip — identical everywhere.
struct RailControlButton: View {
    let systemName: String
    let help: String
    var color: Color
    var isLightMode: Bool
    let action: () -> Void
    // @StateObject rather than @State: this project builds with the Command Line Tools,
    // which ship without the SwiftUI macro plugin that @State now requires.
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hover.isHovered ? (isLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08)) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(RailPressStyle())
        .onHover { hovering in
            withAnimation(Motion.fade) { hover.isHovered = hovering }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// Press feedback shared by rail controls.
struct RailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

@MainActor
final class ToolReorderManager: ObservableObject {
    @Published var pressedToolID: String? = nil
    @Published var hoveredToolID: String? = nil
    @Published var draggedToolID: String? = nil
    @Published var dragOffsetY: CGFloat = 0
    @Published var initialIndex: Int = 0
    @Published var targetIndex: Int = 0
    @Published var isDragging: Bool = false

    private let slotHeight: CGFloat = 50.0 // 44pt item + 6pt spacing

    func beginDrag(toolID: String, index: Int) {
        draggedToolID = toolID
        initialIndex = index
        targetIndex = index
        dragOffsetY = 0
        isDragging = true
    }

    func updateDrag(translationY: CGFloat, totalCount: Int) {
        guard isDragging, totalCount > 0 else { return }
        dragOffsetY = translationY
        let slotsMoved = Int(round(translationY / slotHeight))
        let newTarget = max(0, min(totalCount - 1, initialIndex + slotsMoved))
        if newTarget != targetIndex {
            targetIndex = newTarget
        }
    }

    func endDrag(tools: [ToolItem], configStore: ConfigStore) {
        let sourceID = draggedToolID
        let srcIdx = initialIndex
        let tgtIdx = targetIndex
        let didDrag = isDragging

        draggedToolID = nil
        hoveredToolID = nil
        dragOffsetY = 0
        initialIndex = 0
        targetIndex = 0
        isDragging = false

        guard didDrag,
              let sID = sourceID,
              srcIdx != tgtIdx,
              srcIdx >= 0, srcIdx < tools.count,
              tgtIdx >= 0, tgtIdx < tools.count else {
            return
        }

        let targetID = tools[tgtIdx].id
        configStore.reorderTools(sourceID: sID, targetID: targetID)
    }

    func visualOffset(for toolID: String, at index: Int) -> CGFloat {
        guard let draggedID = draggedToolID, isDragging else { return 0 }

        if toolID == draggedID {
            return dragOffsetY
        }

        if initialIndex < targetIndex {
            // Dragging down: items between initialIndex + 1 and targetIndex shift UP by 1 slot (-50pt)
            if index > initialIndex && index <= targetIndex {
                return -slotHeight
            }
        } else if initialIndex > targetIndex {
            // Dragging up: items between targetIndex and initialIndex - 1 shift DOWN by 1 slot (+50pt)
            if index >= targetIndex && index < initialIndex {
                return slotHeight
            }
        }

        return 0
    }
}

extension Color {
    init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 33, 33, 33)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
