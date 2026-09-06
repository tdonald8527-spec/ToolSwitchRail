import AppKit
import ApplicationServices

@MainActor
protocol WindowTrackerDelegate: AnyObject {
    func windowTracker(_ tracker: WindowTracker, didUpdateTargetFrame targetFrame: CGRect, railFrame: CGRect)
    func windowTrackerDidMinimizeTarget(_ tracker: WindowTracker)
    func windowTrackerDidDeminimizeTarget(_ tracker: WindowTracker)
    func windowTrackerDidDestroyTarget(_ tracker: WindowTracker)
    func windowTrackerDidSettle(_ tracker: WindowTracker)
}

@MainActor
final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?

    private(set) var currentApp: NSRunningApplication?
    private(set) var currentWindow: AXUIElement?
    private(set) var currentTool: ToolItem?

    private var railWidth: CGFloat = 56
    private var axObserver: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var dragPollTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var trackedWindowID: CGWindowID = 0

    private var lastTargetFrame: CGRect = .zero
    private var isTracking = false
    var isRailDragging = false
    private var restoreUntil: Date = .distantPast
    private var mouseButtonsDown = false
    private var lastDragCheckTime: TimeInterval = 0

    // Native minimize has a visible system animation. Do not let the workspace react
    // until that animation has settled, otherwise app.hide()/restore notifications can
    // make the window appear to bounce back before disappearing.
    private var minimizePendingUntil: Date = .distantPast
    private var minimizeConfirmationGeneration: UInt = 0

    var isMouseDragging: Bool {
        mouseButtonsDown
    }

    init(railWidth: CGFloat = 56) {
        self.railWidth = railWidth
    }

    func markRestoring(duration: TimeInterval = 0.6) {
        restoreUntil = Date().addingTimeInterval(duration)
        cancelPendingMinimizeConfirmation()
    }

    func currentWindowAXPosition() -> CGPoint? {
        guard let window = currentWindow else { return nil }
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              let posAX = posValue,
              CFGetTypeID(posAX) == AXValueGetTypeID() else {
            return nil
        }
        var axPoint = CGPoint.zero
        AXValueGetValue(posAX as! AXValue, .cgPoint, &axPoint)
        return axPoint
    }

    func updateRailWidth(_ width: CGFloat) {
        railWidth = width
    }

    func startTracking(app: NSRunningApplication, window: AXUIElement, tool: ToolItem) {
        stopTracking(keepLastFrame: true)

        currentApp = app
        currentWindow = window
        currentTool = tool
        isTracking = true
        trackedWindowID = Self.windowID(for: window) ?? 0

        setupAXObserver(for: app, window: window)
        startPolling()
        startMouseMonitoring()
        checkWindowFrame(force: true)
    }

    func stopTracking(keepLastFrame: Bool = false) {
        isTracking = false
        cancelPendingMinimizeConfirmation()
        let appDied = currentApp?.isTerminated ?? false

        if let observer = axObserver, let source = observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            if !appDied, let window = currentWindow {
                AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXWindowMiniaturizedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXWindowDeminiaturizedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
            }
        }
        axObserver = nil
        observerSource = nil

        pollTimer?.invalidate()
        pollTimer = nil
        stopDragPolling()

        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors.removeAll()
        mouseButtonsDown = false

        currentWindow = nil
        currentApp = nil
        currentTool = nil
        trackedWindowID = 0

        if !keepLastFrame {
            lastTargetFrame = .zero
        }
    }

    private func setupAXObserver(for app: NSRunningApplication, window: AXUIElement) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            if Thread.isMainThread {
                tracker.handleNotification(element: element, notification: notification)
            } else {
                DispatchQueue.main.async {
                    tracker.handleNotification(element: element, notification: notification)
                }
            }
        }

        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success,
              let observer else {
            return
        }

        axObserver = observer
        let source = AXObserverGetRunLoopSource(observer)
        observerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, selfPtr)
        _ = AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, selfPtr)
        _ = AXObserverAddNotification(observer, window, kAXWindowMiniaturizedNotification as CFString, selfPtr)
        _ = AXObserverAddNotification(observer, window, kAXWindowDeminiaturizedNotification as CFString, selfPtr)
        _ = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, selfPtr)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkWindowFrame(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startDragPolling() {
        guard dragPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if now - self.lastDragCheckTime >= (1.0 / 65.0) {
                    self.lastDragCheckTime = now
                    self.checkWindowFrame(force: false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragPollTimer = timer
    }

    private func stopDragPolling() {
        dragPollTimer?.invalidate()
        dragPollTimer = nil
    }

    private func startMouseMonitoring() {
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors.removeAll()

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let apply = {
                switch event.type {
                case .leftMouseDown:
                    self.mouseButtonsDown = true
                    self.startDragPolling()
                    self.lastDragCheckTime = CACurrentMediaTime()
                    self.checkWindowFrame(force: false)
                case .leftMouseDragged:
                    if !self.mouseButtonsDown {
                        self.mouseButtonsDown = true
                        self.startDragPolling()
                    }
                    let now = CACurrentMediaTime()
                    if now - self.lastDragCheckTime >= (1.0 / 65.0) {
                        self.lastDragCheckTime = now
                        self.checkWindowFrame(force: false)
                    }
                case .leftMouseUp:
                    self.mouseButtonsDown = false
                    self.stopDragPolling()
                    self.checkWindowFrame(force: true)
                    self.delegate?.windowTrackerDidSettle(self)
                default:
                    break
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(apply)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated(apply)
                }
            }
        }

        if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: handler) {
            mouseMonitors.append(down)
        }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: handler) {
            mouseMonitors.append(drag)
        }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: handler) {
            mouseMonitors.append(up)
        }
    }

    private func handleNotification(element: AXUIElement, notification: CFString) {
        guard isTracking else { return }

        if notification == kAXMovedNotification as CFString || notification == kAXResizedNotification as CFString {
            checkWindowFrame(force: true)
        } else if notification == kAXWindowMiniaturizedNotification as CFString {
            scheduleExternalMinimizeConfirmation()
        } else if notification == kAXWindowDeminiaturizedNotification as CFString {
            cancelPendingMinimizeConfirmation()
            checkWindowFrame(force: true)
            delegate?.windowTrackerDidDeminimizeTarget(self)
        } else if notification == kAXUIElementDestroyedNotification as CFString {
            delegate?.windowTrackerDidDestroyTarget(self)
            stopTracking(keepLastFrame: false)
        }
    }

    private func cancelPendingMinimizeConfirmation() {
        minimizeConfirmationGeneration &+= 1
        minimizePendingUntil = .distantPast
    }

    private func scheduleExternalMinimizeConfirmation() {
        guard Date() >= restoreUntil else { return }

        minimizeConfirmationGeneration &+= 1
        let generation = minimizeConfirmationGeneration
        minimizePendingUntil = Date().addingTimeInterval(0.18)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self,
                  self.isTracking,
                  generation == self.minimizeConfirmationGeneration,
                  Date() >= self.restoreUntil,
                  let window = self.currentWindow else {
                return
            }

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
            guard result == .success, (value as? Bool) == true else {
                self.minimizePendingUntil = .distantPast
                return
            }

            self.minimizePendingUntil = .distantPast
            self.delegate?.windowTrackerDidMinimizeTarget(self)
        }
    }

    func checkWindowFrame(force: Bool = false) {
        if isRailDragging && !force { return }
        guard let window = currentWindow else { return }

        if Date() >= restoreUntil {
            if let app = currentApp, app.isHidden {
                delegate?.windowTrackerDidMinimizeTarget(self)
                return
            }

            if !mouseButtonsDown {
                var minVal: CFTypeRef?
                let minErr = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minVal)
                if minErr == .invalidUIElement || minErr == .cannotComplete {
                    delegate?.windowTrackerDidDestroyTarget(self)
                    return
                }
                if minErr == .success, let minimized = minVal as? Bool, minimized {
                    if Date() >= minimizePendingUntil {
                        scheduleExternalMinimizeConfirmation()
                    }
                    return
                }
            }
        }

        var liveFrame: CGRect?
        if let cgFrame = cgWindowFrame() {
            liveFrame = cgFrame
        } else {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?

            let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
            let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)

            if posErr == .invalidUIElement || sizeErr == .invalidUIElement {
                delegate?.windowTrackerDidDestroyTarget(self)
                return
            }

            guard posErr == .success, sizeErr == .success,
                  let posAX = posValue, let sizeAX = sizeValue else {
                return
            }

            var axPoint = CGPoint.zero
            var axSize = CGSize.zero
            if CFGetTypeID(posAX) == AXValueGetTypeID() {
                AXValueGetValue(posAX as! AXValue, .cgPoint, &axPoint)
            }
            if CFGetTypeID(sizeAX) == AXValueGetTypeID() {
                AXValueGetValue(sizeAX as! AXValue, .cgSize, &axSize)
            }
            guard axSize.width > 50 && axSize.height > 50 else { return }
            liveFrame = convertToNSCoordinates(axPoint: axPoint, axSize: axSize)
        }

        guard let validLiveFrame = liveFrame else { return }
        let nsTargetFrame = CGRect(
            x: validLiveFrame.origin.x.rounded(),
            y: validLiveFrame.origin.y.rounded(),
            width: validLiveFrame.size.width.rounded(),
            height: validLiveFrame.size.height.rounded()
        )

        if !force && framesClose(nsTargetFrame, lastTargetFrame) {
            return
        }
        lastTargetFrame = nsTargetFrame

        let railFrame = CGRect(
            x: nsTargetFrame.minX - railWidth,
            y: nsTargetFrame.minY,
            width: railWidth,
            height: nsTargetFrame.height
        )
        delegate?.windowTracker(self, didUpdateTargetFrame: nsTargetFrame, railFrame: railFrame)
    }

    private func framesClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 &&
        abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 &&
        abs(a.height - b.height) < 0.5
    }

    private func cgWindowFrame() -> CGRect? {
        var windowID = trackedWindowID
        if windowID == 0, let window = currentWindow {
            windowID = Self.windowID(for: window) ?? 0
            trackedWindowID = windowID
        }
        guard windowID > 0 else { return nil }

        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let x = bounds["X"] as? NSNumber,
              let y = bounds["Y"] as? NSNumber,
              let w = bounds["Width"] as? NSNumber,
              let h = bounds["Height"] as? NSNumber else {
            return nil
        }

        let size = CGSize(width: w.doubleValue, height: h.doubleValue)
        guard size.width > 50 && size.height > 50 else { return nil }
        return convertToNSCoordinates(
            axPoint: CGPoint(x: x.doubleValue, y: y.doubleValue),
            axSize: size
        )
    }

    private static let _axGetWindowFunc: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let fn = _axGetWindowFunc else { return nil }
        var wid: CGWindowID = 0
        if fn(element, &wid) == .success, wid > 0 {
            return wid
        }
        return nil
    }

    private func convertToNSCoordinates(axPoint: CGPoint, axSize: CGSize) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 1080
        let nsY = primaryHeight - axPoint.y - axSize.height
        return CGRect(x: axPoint.x, y: nsY, width: axSize.width, height: axSize.height)
    }
}
