import AppKit
import SwiftUI

final class KeyableRailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RailWindowController: NSWindowController {
    private let configStore: ConfigStore
    private let windowManager: WindowManager
    private let statusMonitor: ToolStatusMonitor
    private var priorFrontmostApp: NSRunningApplication?
    private var visibilityAnimationGeneration: UInt = 0
    private var hostingView: NSHostingView<RailView>?
    private let toastPanel = ToastPanelController()

    static let seamExtension: CGFloat = 1

    init(configStore: ConfigStore, windowManager: WindowManager, statusMonitor: ToolStatusMonitor, onSelect: @escaping (ToolItem) -> Void) {
        self.configStore = configStore
        self.windowManager = windowManager
        self.statusMonitor = statusMonitor

        let cfg = configStore.configuration.workspace
        let totalWidth = cfg.railWidth + Double(Self.seamExtension)
        let panel = KeyableRailPanel(
            contentRect: CGRect(x: 0, y: 0, width: totalWidth, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        // Normal window level (2026-11-25): the rail belongs to the workspace, not above
        // every app. Other apps the user switches to cover it like any other window.
        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // Seamless join without drop shadow bleeding into official window
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false

        let railView = RailView(
            configStore: configStore,
            windowManager: windowManager,
            statusMonitor: statusMonitor,
            onSelect: onSelect
        )
        let hosting = NSHostingView(rootView: railView)
        hosting.wantsLayer = true
        // Round ONLY the top-left and bottom-left corners (~10px standard macOS window radius)
        hosting.layer?.cornerRadius = 10
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        let container = RailContainerView(hostingView: hosting, windowManager: windowManager)
        panel.contentView = container

        super.init(window: panel)
        applyAppearance(for: nil)
    }

    func prepareForKeyInteraction() {
        guard let window else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            priorFrontmostApp = front
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKey()
    }

    func restorePriorFrontmostApp() {
        if let app = priorFrontmostApp, !app.isTerminated {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        priorFrontmostApp = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func move(to frame: CGRect) {
        guard let window else { return }
        let width = CGFloat(configStore.configuration.workspace.railWidth)
        let totalWidth = width + Self.seamExtension
        let adjustedFrame = CGRect(x: frame.minX, y: frame.minY, width: totalWidth, height: frame.height)
        let currentFrame = window.frame
        toastPanel.updateAnchor(railFrame: adjustedFrame)
        if currentFrame.equalTo(adjustedFrame) { return }

        if currentFrame.size.equalTo(adjustedFrame.size) {
            // Origin-only move during dragging: pure hardware surface translation, zero redraw latency
            window.setFrameOrigin(adjustedFrame.origin)
        } else {
            // Size changed during resize: non-blocking layout pass
            window.setFrame(adjustedFrame, display: false, animate: false)
        }
    }

    func setFloatingForManagedTool(_ isManaged: Bool) {
        guard let window, !windowManager.isMinimized else { return }
        // Cancels a pending fade-out; if one was underway, glide back instead of snapping.
        visibilityAnimationGeneration &+= 1
        if window.alphaValue < 0.99 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.windowFadeDuration
                window.animator().alphaValue = 1
            }
        }

        if window.level != .normal {
            window.level = .normal
            if let panel = window as? NSPanel {
                panel.isFloatingPanel = false
            }
        }
        if isManaged {
            // A rail tool is in front: bring the rail up with it.
            window.orderFrontRegardless()
        } else if !window.isVisible {
            // Another app is in front: stay visible but keep our place in the stack, so
            // that app's windows cover the rail instead of the rail covering them.
            window.orderBack(nil)
        }
    }

    func orderAdjacentToTargetWindow(targetWindowID: CGWindowID? = nil) {
        guard let window else { return }
        let trackedPID = windowManager.currentTargetPID
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if trackedPID != nil, trackedPID == frontPID {
            // The rail's own tool is active: sit on top, next to it.
            window.orderFrontRegardless()
        } else if let wid = targetWindowID, wid > 0 {
            // Otherwise stay directly above the tool's window only, below whatever the
            // user is working in.
            window.order(.above, relativeTo: Int(wid))
        } else if !window.isVisible {
            window.orderBack(nil)
        }
    }

    func setOrigin(_ origin: CGPoint) {
        window?.setFrameOrigin(origin)
    }

    /// Short fade out, then order out. The generation counter keeps it atomic: any newer
    /// show / switch cancels a fade that is still running, so a stale fade can never hide
    /// the rail after it was asked to come back.
    func hide() {
        guard let window else { return }
        visibilityAnimationGeneration &+= 1
        let generation = visibilityAnimationGeneration
        ToastCenter.shared.dismiss()
        guard window.isVisible else { window.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.windowFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, generation == self.visibilityAnimationGeneration else { return }
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }

    /// Fade in from wherever the rail currently is (also from a half-finished fade out).
    func show(relativeTo targetWindowID: CGWindowID? = nil) {
        guard let window else { return }
        visibilityAnimationGeneration &+= 1
        let wasVisible = window.isVisible && window.alphaValue > 0.99
        if !window.isVisible { window.alphaValue = 0 }
        orderAdjacentToTargetWindow(targetWindowID: targetWindowID)
        guard !wasVisible else { window.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.windowFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func applyAppearance(for tool: ToolItem? = nil) {
        guard let window else { return }
        let targetAppearanceName: NSAppearance.Name
        let mode = configStore.configuration.workspace.appearance
        switch mode {
        case .light:
            targetAppearanceName = .aqua
        case .dark:
            targetAppearanceName = .darkAqua
        case .system:
            targetAppearanceName = SystemAppearanceManager.shared.isDarkMode ? .darkAqua : .aqua
        }

        if window.appearance?.name != targetAppearanceName {
            window.appearance = NSAppearance(named: targetAppearanceName)
        }
        if hostingView?.appearance?.name != targetAppearanceName {
            hostingView?.appearance = NSAppearance(named: targetAppearanceName)
        }
    }
}

@MainActor
final class RailContainerView: NSView {
    private weak var windowManager: WindowManager?
    private var hostingView: NSView?

    enum ResizeEdge {
        case none
        case left
        case bottom
        case top
        case bottomLeft
        case topLeft
    }

    private var activeEdge: ResizeEdge = .none
    private var dragStartMouseLocation: CGPoint = .zero
    private var dragStartRailFrame: CGRect = .zero
    private var dragStartTargetFrame: CGRect = .zero
    private let borderThickness: CGFloat = 3
    private let cornerSize: CGFloat = 6

    init(hostingView: NSView, windowManager: WindowManager) {
        self.windowManager = windowManager
        self.hostingView = hostingView
        super.init(frame: hostingView.bounds)
        self.autoresizingMask = [.width, .height]
        self.addSubview(hostingView)
        hostingView.frame = self.bounds
        hostingView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let t = borderThickness
        let c = cornerSize
        let w = bounds.width
        let h = bounds.height

        // Bottom-left and top-left corners (only in middle zone to avoid traffic light / bottom gear)
        if h > 80 {
            addCursorRect(CGRect(x: 0, y: 40, width: c, height: c), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 0, y: h - 40 - c, width: c, height: c), cursor: .resizeUpDown)
        }

        // Left edge
        addCursorRect(CGRect(x: 0, y: 0, width: t, height: h), cursor: .resizeLeftRight)

        // Bottom and top edges (only between 40 and h-40)
        if w > c {
            addCursorRect(CGRect(x: c, y: 0, width: w - c, height: t), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: c, y: max(0, h - t), width: w - c, height: t), cursor: .resizeUpDown)
        }
    }

    private func edge(at point: CGPoint) -> ResizeEdge {
        let t = borderThickness
        let c = cornerSize
        let h = bounds.height

        // Protect top 40pt (traffic lights + header drag) and bottom 40pt (plus/gear buttons)
        if point.y >= h - 40 || point.y <= 40 {
            if point.x <= t {
                return .left
            }
            return .none
        }

        if point.x <= t {
            if point.y <= c { return .bottomLeft }
            if point.y >= h - c { return .topLeft }
            return .left
        }
        if point.y <= t {
            return .bottom
        }
        if point.y >= h - t {
            return .top
        }
        return .none
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? convert(point, from: nil)
        let detected = edge(at: local)
        if detected != .none {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        activeEdge = edge(at: local)
        if activeEdge != .none {
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartRailFrame = window?.frame ?? .zero
            dragStartTargetFrame = windowManager?.activeContentFrame ?? .zero
            windowManager?.beginRailResize()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeEdge != .none, let wm = windowManager else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - dragStartMouseLocation.x
        let dy = currentMouse.y - dragStartMouseLocation.y

        let isLeft = (activeEdge == .left || activeEdge == .bottomLeft || activeEdge == .topLeft)
        let isBottom = (activeEdge == .bottom || activeEdge == .bottomLeft)
        let isTop = (activeEdge == .top || activeEdge == .topLeft)

        wm.handleRailResize(
            isLeft: isLeft,
            isBottom: isBottom,
            isTop: isTop,
            dx: dx,
            dy: dy,
            startRailFrame: dragStartRailFrame,
            startTargetFrame: dragStartTargetFrame
        )
    }

    override func mouseUp(with event: NSEvent) {
        if activeEdge != .none {
            activeEdge = .none
            windowManager?.endRailResize()
            return
        }
        super.mouseUp(with: event)
    }
}
