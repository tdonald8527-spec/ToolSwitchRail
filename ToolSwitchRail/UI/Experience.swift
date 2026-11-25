import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Motion language
//
// One motion vocabulary for the whole app. Every animated state change uses one of
// these, so the same kind of change always moves the same way.
//   quick    – press / hover feedback (frequent, must feel instant)
//   standard – selection, reorder, insert / remove, toasts (explains where things go)
//   fade     – colour and opacity changes (no movement)
// With "Reduce motion" on, movement collapses to short fades and nothing loops.
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var quick: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.16, dampingFraction: 0.9)
    }

    static var standard: Animation {
        reduceMotion ? .easeInOut(duration: 0.14) : .spring(response: 0.3, dampingFraction: 0.88)
    }

    static var fade: Animation {
        .easeInOut(duration: reduceMotion ? 0.12 : 0.18)
    }

    /// Gentle "launching" breathing. nil under Reduce motion (shown as a static dim instead).
    static var launching: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    /// Insert / remove of an item in place.
    static var appear: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }

    /// Something entering from an edge (toasts).
    static func slide(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: edge))
    }

    /// Window-level fades (AppKit), in seconds.
    static var windowFadeDuration: TimeInterval { reduceMotion ? 0.1 : 0.15 }
}

// MARK: - One vocabulary for tool state

enum ToolStateLabel {
    /// The only four states shown anywhere: 未启动 / 启动中 / 当前 / 运行中.
    static func text(isLaunching: Bool, isSelected: Bool, isOpen: Bool) -> String {
        if isLaunching { return "启动中" }
        if isSelected && isOpen { return "当前" }
        if isOpen { return "运行中" }
        return "未启动"
    }

    static func color(isLaunching: Bool, isSelected: Bool, isOpen: Bool) -> Color {
        if isLaunching { return Color.accentColor.opacity(0.6) }
        if isSelected && isOpen { return Color.accentColor }
        if isOpen { return Color.green }
        return Color.secondary.opacity(0.35)
    }
}

// MARK: - Toasts (non-blocking feedback next to the rail)

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?
    private var isHovering = false

    func show(_ message: String, actionTitle: String? = nil, duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        withAnimation(Motion.standard) {
            current = Toast(message: message, actionTitle: actionTitle, action: action)
        }
        scheduleDismiss(after: duration)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard current != nil else { return }
        withAnimation(Motion.standard) { current = nil }
    }

    func performAction() {
        let action = current?.action
        dismiss()
        action?()
    }

    /// Hovering keeps the toast; leaving gives a short grace period.
    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            dismissTask?.cancel()
        } else if current != nil {
            scheduleDismiss(after: 2.5)
        }
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        let id = current?.id
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isHovering, self.current?.id == id else { return }
            self.dismiss()
        }
    }
}

struct ToastView: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        ZStack(alignment: .leading) {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Text(toast.message)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .fixedSize()
                    if let title = toast.actionTitle {
                        Button(title) { center.performAction() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 2)
                .onHover { center.setHovering($0) }
                .id(toast.id)
                .transition(Motion.slide(.leading))
            }
        }
        .padding(8)
        .fixedSize()
    }
}

/// Small floating panel beside the rail that hosts the toast. It only exists on screen
/// while a toast is visible, so it never swallows clicks meant for the app underneath.
@MainActor
final class ToastPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<ToastView>
    private var cancellable: AnyCancellable?
    private var anchor: CGRect = .zero
    private var hideGeneration: UInt = 0

    init() {
        hosting = NSHostingView(rootView: ToastView())
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting

        cancellable = ToastCenter.shared.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] toast in
                self?.update(hasToast: toast != nil)
            }
    }

    /// Called whenever the rail moves.
    func updateAnchor(railFrame: CGRect) {
        anchor = railFrame
        if panel.isVisible { reposition() }
    }

    private func update(hasToast: Bool) {
        hideGeneration &+= 1
        if hasToast {
            // Let SwiftUI lay out the new toast first, then size the panel to it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reposition()
                self.panel.orderFrontRegardless()
            }
        } else {
            // Keep the panel until the exit transition has played.
            let generation = hideGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.hideGeneration == generation, ToastCenter.shared.current == nil else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func reposition() {
        guard anchor.width > 0 else { return }
        let size = hosting.fittingSize
        // Bottom of the rail, just outside its right edge, level with the bottom controls.
        panel.setFrame(CGRect(x: anchor.maxX + 2, y: anchor.minY + 14, width: size.width, height: size.height), display: true)
    }
}

// MARK: - Shared actions (one behaviour, every entry point)

@MainActor
enum RailActions {
    /// Removing is immediate and undoable — never a confirmation dialog.
    static func removeTool(id: String, configStore: ConfigStore) {
        var removed: (tool: ToolItem, index: Int)?
        withAnimation(Motion.standard) {
            removed = configStore.removeTool(id: id)
        }
        guard let removed else { return }
        ToastCenter.shared.show("已移除「\(removed.tool.name)」", actionTitle: "撤销") {
            withAnimation(Motion.standard) {
                configStore.restoreTool(removed.tool, at: removed.index)
            }
        }
    }

    /// "+ 添加应用": pick an .app, add it, switch to it.
    static func addApp(configStore: ConfigStore, windowManager: WindowManager, completion: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        panel.message = "选择要放到 Rail 上的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var added: ToolItem?
        withAnimation(Motion.standard) {
            added = configStore.addTool(fromAppURL: url)
        }
        if let added {
            windowManager.switchTo(added)
            completion?()
        }
    }

    static func openAccessibilitySettings() {
        AccessibilityPermission.promptIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
