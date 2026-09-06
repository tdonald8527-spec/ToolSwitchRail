import SwiftUI
import AppKit

struct RailView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var statusMonitor: ToolStatusMonitor
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

    private var currentBackgroundColor: Color {
        if let tool = currentTool {
            return Color(hex: tool.resolvedBackgroundColor)
        }
        return Color(hex: "#212121")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Adaptive Solid Background matching the active tool (fills full width including 16pt flange)
            currentBackgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.22), value: currentBackgroundColor)

            // Subtle hairline divider between rail and target app (padded 14pt vertically to preserve corner seams)
            HStack(spacing: 0) {
                Spacer().frame(width: max(0, railWidth - 0.5))
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.5)
                    .padding(.vertical, 14)
                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                RailHeaderDragArea(windowManager: windowManager)
                    .padding(.top, 8)

                NeedsYouButton(
                    statusMonitor: statusMonitor,
                    windowManager: windowManager,
                    tools: tools,
                    onOpen: onSelect
                )

                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    let isBeingDragged = reorderManager.draggedToolID == tool.id
                    let itemOffset = reorderManager.visualOffset(for: tool.id, at: index)

                    ToolIconView(
                        tool: tool,
                        isSelected: windowManager.selectedToolID == tool.id,
                        isPressed: reorderManager.pressedToolID == tool.id,
                        isHovered: reorderManager.hoveredToolID == tool.id,
                        isLaunching: windowManager.launchingToolID == tool.id,
                        isOpen: windowManager.openToolIDs.contains(tool.id),
                        status: statusMonitor.snapshot(for: tool.id).status,
                        usageText: statusMonitor.snapshot(for: tool.id).usageText,
                        namespace: railNamespace
                    )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isBeingDragged ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .scaleEffect(isBeingDragged ? 1.08 : 1.0)
                        .shadow(color: isBeingDragged ? Color.black.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
                        .offset(y: itemOffset)
                        .animation(isBeingDragged ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: itemOffset)
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
                        .onTapGesture {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                onSelect(tool)
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { value in
                                    let dy = value.translation.height
                                    if !reorderManager.isDragging {
                                        reorderManager.beginDrag(toolID: tool.id, index: index)
                                    }
                                    reorderManager.updateDrag(translationY: dy, totalCount: tools.count)
                                }
                                .onEnded { _ in
                                    if reorderManager.isDragging {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            reorderManager.endDrag(tools: tools, configStore: configStore)
                                        }
                                    }
                                }
                        )
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

                Divider()
                    .padding(.horizontal, 10)
                    .opacity(0.4)

                Button {
                    configStore.openConfigFile()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.primary.opacity(0.7))
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加工具：编辑 config.json")

                Button {
                    windowManager.showSettingsMenu()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.primary.opacity(0.7))
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")

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
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: windowManager.selectedToolID)

            if let error = windowManager.lastError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                        .onTapGesture { windowManager.lastError = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RailHeaderDragArea: View {
    @ObservedObject var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                TrafficLightMinimizeButton {
                    windowManager.minimizeCurrent()
                }

                TrafficLightZoomButton {
                    windowManager.toggleMaximize()
                }
            }

            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 22, height: 3)
        }
        .frame(width: 56, height: 34)
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
        .onTapGesture(count: 2) {
            windowManager.toggleMaximize()
        }
    }
}

struct TrafficLightMinimizeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.99, green: 0.74, blue: 0.18))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 0.88, green: 0.62, blue: 0.11), lineWidth: 0.5)
                    )

                Image(systemName: "minus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.55))
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("最小化 (Cmd+Option+M)")
    }
}

struct TrafficLightZoomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 0.12, green: 0.65, blue: 0.20), lineWidth: 0.5)
                    )

                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.55))
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("最大化 / 还原")
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
