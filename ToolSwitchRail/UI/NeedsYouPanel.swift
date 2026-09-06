import SwiftUI

struct NeedsYouButton: View {
    @ObservedObject var statusMonitor: ToolStatusMonitor
    @ObservedObject var windowManager: WindowManager
    let tools: [ToolItem]
    let onOpen: (ToolItem) -> Void
    @StateObject private var panelState = NeedsYouOpenState()

    private var count: Int { statusMonitor.needsYouItems.count }

    var body: some View {
        Button {
            if !panelState.isOpen {
                windowManager.prepareForKeyInteraction()
            }
            panelState.isOpen.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: count > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(count > 0 ? Color(red: 0.98, green: 0.72, blue: 0.16) : .primary.opacity(0.7))
                    .frame(width: 40, height: 28)

                if count > 0 {
                    Text(count > 9 ? "9+" : "\(count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.92, green: 0.32, blue: 0.22), in: Capsule())
                        .offset(x: 2, y: -1)
                }
            }
            .frame(width: 40, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count == 0 ? "Needs You" : "Needs You · \(count)")
        .popover(isPresented: $panelState.isOpen, arrowEdge: .trailing) {
            NeedsYouPanel(
                items: statusMonitor.needsYouItems,
                tools: tools,
                onOpen: { tool in
                    panelState.isOpen = false
                    onOpen(tool)
                }
            )
            .frame(width: 320)
        }
        .onChange(of: panelState.isOpen) { _, isOpen in
            if isOpen {
                windowManager.prepareForKeyInteraction()
            } else {
                windowManager.restorePriorFrontmostApp()
            }
        }
    }
}

struct NeedsYouPanel: View {
    let items: [NeedsYouItem]
    let tools: [ToolItem]
    let onOpen: (ToolItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs You")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 2)

            if items.isEmpty {
                Text("没有需要你处理的任务")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .center, spacing: 10) {
                        Circle()
                            .fill(item.status.dotColor)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.toolName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(item.status.shortLabel)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if let title = item.taskTitle, !title.isEmpty {
                                Text(title)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        Button("Open") {
                            if let tool = tools.first(where: { $0.id == item.toolID }) {
                                onOpen(tool)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

final class NeedsYouOpenState: ObservableObject {
    @Published var isOpen = false
}
