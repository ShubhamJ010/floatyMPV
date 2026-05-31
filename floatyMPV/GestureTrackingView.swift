import AppKit
import QuartzCore

/// `GestureTrackingView` is a custom `NSView` subclass responsible for handling
/// complex user input gestures on macOS, such as dragging, pinching, and touch events.
///
/// Because SwiftUI's gesture system is simplified, we use AppKit's lower-level `NSResponder`
/// methods (like `mouseDown`, `touchesBegan`, `scrollWheel`, `magnify`)
/// to achieve precise, high-performance interactions required for this application.
final class GestureTrackingView: NSView {
    /// A closure used to inform SwiftUI of changes to the "pickup" state.
    /// It bridges the AppKit event world to the SwiftUI state world.
    var onPickedUpChanged: ((Bool) -> Void)?

    /// The playback controller that keyboard shortcuts target.
    var playerController: MPVController?

    private var trackedTouches: [ObjectIdentifier: NSPoint] = [:]
    private var lastCentroid: NSPoint?
    private var pickupActive = false
    private var cursorHidden = false
    private var pinchBaseFrame: NSRect?
    private var pinchBaseCenter: NSPoint?
    private var pinchAccumulatedScale: CGFloat = 1.0
    private var pinchHitMinDuringCurrentGesture = false
    private var pinchHitMaxDuringCurrentGesture = false
    private let pickupWindowScale: CGFloat = 1.0
    private var pendingDropWorkItem: DispatchWorkItem?
    private let pickupDropDebounce: TimeInterval = 0.08
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var appDidResignActiveObserver: Any?
    private var mouseDragStartWindowFrame: NSRect?
    private var mouseDragStartScreenPoint: NSPoint?
    private let snapEngine = SnapEngine()
    private var recentScrollSamples: [ScrollSample] = []
    private var snapAnimationInFlight = false

    // MARK: - Display-Link Driven Smooth Scrolling
    /// Instead of calling `setFrame` on every scroll event (which causes jitter
    /// when events arrive faster than the display refresh), we accumulate deltas
    /// and apply them at vsync-aligned intervals via CVDisplayLink.
    private var displayLink: CVDisplayLink?
    private var pendingScrollDelta: CGPoint = .zero
    private var accumulatedScrollDelta: CGPoint = .zero  // for interpolation
    private let smoothingFactor: CGFloat = 0.4
    private let displayLinkLock = NSLock()
    private var displayLinkActive = false
    private var isDraggingWithScroll = false

    /// `acceptsFirstResponder` must return `true` to enable the view to receive
    /// mouse events and keyboard input.
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        allowedTouchTypes = [.indirect]
        acceptsTouchEvents = true
        wantsRestingTouches = true

        installScrollMonitorsIfNeeded()
        installAppStateObserversIfNeeded()
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect]
        acceptsTouchEvents = true
        wantsRestingTouches = true
        installScrollMonitorsIfNeeded()
        installAppStateObserversIfNeeded()
        startDisplayLink()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    deinit {
        cancelPendingDrop()
        stopDisplayLink()
        removeScrollMonitors()
        removeAppStateObservers()
        showCursorIfNeeded()
    }

    // MARK: - Touch Handling (Trackpad)

    override func touchesBegan(with event: NSEvent) {
        updateTrackedTouches(with: event)
        handleTouchState()
        super.touchesBegan(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        updateTrackedTouches(with: event)
        handleTouchState()
        super.touchesMoved(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        updateTrackedTouches(with: event)
        handleTouchState()
        super.touchesEnded(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        resetPickupState(reason: "touches-cancelled")
        super.touchesCancelled(with: event)
    }

    // MARK: - Mouse Handling (Click & Drag)

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        mouseDragStartWindowFrame = window.frame
        mouseDragStartScreenPoint = window.convertPoint(toScreen: event.locationInWindow)

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let startFrame = mouseDragStartWindowFrame,
            let startPoint = mouseDragStartScreenPoint
        else {
            super.mouseDragged(with: event)
            return
        }

        let currentPoint = window.convertPoint(toScreen: event.locationInWindow)
        let dx = currentPoint.x - startPoint.x
        let dy = currentPoint.y - startPoint.y

        var nextFrame = startFrame
        nextFrame.origin.x += dx
        nextFrame.origin.y += dy

        window.setFrame(nextFrame, display: false, animate: false)
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragStartWindowFrame = nil
        mouseDragStartScreenPoint = nil

        if trackedTouches.count < 2 {
            resetPickupState(reason: "mouse-up")
        }

        super.mouseUp(with: event)
    }

    // MARK: - Gesture Handling (Scroll, Zoom)

    override func scrollWheel(with event: NSEvent) {
        guard handleScrollMove(with: event, source: "local-view") else {
            super.scrollWheel(with: event)
            return
        }
    }

    /// Processes scroll events to move the window via display-link smoothing.
    private func handleScrollMove(with event: NSEvent, source: String) -> Bool {
        guard let window else { return false }

        if snapAnimationInFlight { return true }
        if source == "global-monitor" && NSApp.isActive { return false }

        if !NSApp.isActive && source == "global-monitor" && !pickupActive {
            let cursorPoint = NSEvent.mouseLocation
            guard window.frame.contains(cursorPoint) else { return false }
            setPickup(active: true)
        }

        guard pickupActive else { return false }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            isDraggingWithScroll = false
            maybeSnapWindowFromRecentSwipe(window: window)
            resetPickupState(reason: "phase-end-\(source)")
            return true
        }

        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale

        if abs(dx) < 0.01 && abs(dy) < 0.01 { return true }

        // Accumulate scroll delta for display-link driven application.
        // We use a weighted average with previous pending delta to smooth out
        // micro-jitter from the trackpad hardware.
        isDraggingWithScroll = true
        let rawDelta = CGPoint(x: dx, y: -dy)
        displayLinkLock.lock()
        // Exponential smoothing on the accumulated delta
        pendingScrollDelta.x = pendingScrollDelta.x * smoothingFactor + rawDelta.x * (1 - smoothingFactor)
        pendingScrollDelta.y = pendingScrollDelta.y * smoothingFactor + rawDelta.y * (1 - smoothingFactor)
        displayLinkLock.unlock()

        recordScrollSample(dx: rawDelta.x, dy: rawDelta.y)

        return true
    }

    override func smartMagnify(with event: NSEvent) {
        guard let window else { return }
        window.zoom(nil)
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }

        if pinchBaseFrame == nil {
            pinchBaseFrame = window.frame
            pinchBaseCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
            pinchAccumulatedScale = 1.0
            pinchHitMinDuringCurrentGesture = false
            pinchHitMaxDuringCurrentGesture = false
        }

        guard let baseFrame = pinchBaseFrame, let baseCenter = pinchBaseCenter else { return }

        let aspectRatio = max(baseFrame.width / max(baseFrame.height, 1.0), 0.01)
        let minWidth = max(window.minSize.width, CGFloat(280))
        let minHeight = max(window.minSize.height, CGFloat(180))
        let maxWidth = CGFloat(589)
        let maxHeight = CGFloat(360)
        let gestureStepScale = max(0.92, min(1.08, 1.0 + event.magnification))
        pinchAccumulatedScale *= gestureStepScale
        let requestedScale = pinchAccumulatedScale

        let scaleFloor = max(minWidth / baseFrame.width, minHeight / baseFrame.height)
        let scaleCeiling = min(maxWidth / baseFrame.width, maxHeight / baseFrame.height)
        let scale = max(scaleFloor, min(scaleCeiling, requestedScale))

        if scale <= scaleFloor + 0.0001 {
            pinchAccumulatedScale = scaleFloor
            if !pinchHitMinDuringCurrentGesture {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                pinchHitMinDuringCurrentGesture = true
            }
        } else {
            pinchHitMinDuringCurrentGesture = false
        }

        if scale >= scaleCeiling - 0.0001 {
            pinchAccumulatedScale = scaleCeiling
            if !pinchHitMaxDuringCurrentGesture {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                pinchHitMaxDuringCurrentGesture = true
            }
        } else {
            pinchHitMaxDuringCurrentGesture = false
        }

        let nextWidth = baseFrame.width * scale
        let nextHeight = nextWidth / aspectRatio
        let nextOrigin = NSPoint(x: baseCenter.x - (nextWidth / 2.0), y: baseCenter.y - (nextHeight / 2.0))
        let nextFrame = NSRect(origin: nextOrigin, size: NSSize(width: nextWidth, height: nextHeight))

        window.setFrame(nextFrame, display: false, animate: false)
    }

    override func endGesture(with event: NSEvent) {
        pinchBaseFrame = nil
        pinchBaseCenter = nil
        pinchAccumulatedScale = 1.0
        pinchHitMinDuringCurrentGesture = false
        pinchHitMaxDuringCurrentGesture = false
        super.endGesture(with: event)
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard let window, let controller = playerController else {
            super.keyDown(with: event)
            return
        }
        if KeyboardShortcutHandler.handle(event, controller: controller, window: window) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Display Link (VSync-Aligned Frame Application)

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }

        let displayLinkOutput: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            let view = Unmanaged<GestureTrackingView>.fromOpaque(displayLinkContext!).takeUnretainedValue()
            view.tickPendingScroll()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, displayLinkOutput, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
        displayLinkActive = true
    }

    private func stopDisplayLink() {
        guard let displayLink = displayLink, displayLinkActive else { return }
        CVDisplayLinkStop(displayLink)
        displayLinkActive = false
    }

    /// Called on CVDisplayLink thread at vsync rate.
    /// Applies the smoothed pending scroll delta to the window frame.
    private func tickPendingScroll() {
        guard isDraggingWithScroll, pickupActive else {
            displayLinkLock.lock()
            pendingScrollDelta = .zero
            displayLinkLock.unlock()
            return
        }

        displayLinkLock.lock()
        let delta = pendingScrollDelta
        if abs(delta.x) < 0.001 && abs(delta.y) < 0.001 {
            pendingScrollDelta = .zero
            displayLinkLock.unlock()
            return
        }
        pendingScrollDelta = .zero
        displayLinkLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.pickupActive, let window = self.window else { return }
            var nextFrame = window.frame
            nextFrame.origin.x += delta.x
            nextFrame.origin.y += delta.y
            window.setFrame(nextFrame, display: false, animate: false)
        }
    }

    // MARK: - State Management

    private func updateTrackedTouches(with event: NSEvent) {
        let activeTouches = event.touches(matching: .touching, in: self)
        var nextTouches: [ObjectIdentifier: NSPoint] = [:]
        for touch in activeTouches {
            let identity = ObjectIdentifier(touch.identity)
            nextTouches[identity] = touch.normalizedPosition
        }
        trackedTouches = nextTouches
    }

    private func handleTouchState() {
        let touchCount = trackedTouches.count

        if touchCount == 2 {
            cancelPendingDrop()
            setPickup(active: true)
            lastCentroid = NSPoint.zero
            return
        }

        if touchCount < 2 {
            scheduleDropIfNeeded()
            lastCentroid = nil
            return
        }

        cancelPendingDrop()
        setPickup(active: false)
    }

    private func setPickup(active: Bool) {
        if pickupActive == active { return }
        if active && !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        pickupActive = active
        if !active {
            recentScrollSamples.removeAll(keepingCapacity: true)
            isDraggingWithScroll = false
        }
        applyPickupWindowScale(active: active)
        if active {
            hideCursorIfNeeded()
        } else {
            showCursorIfNeeded()
        }
        onPickedUpChanged?(active)
    }

    private func scheduleDropIfNeeded() {
        guard pickupActive else { return }
        if pendingDropWorkItem != nil { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDropWorkItem = nil
            if self.trackedTouches.count < 2 {
                self.setPickup(active: false)
            }
        }
        pendingDropWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + pickupDropDebounce, execute: workItem)
    }

    private func cancelPendingDrop() {
        pendingDropWorkItem?.cancel()
        pendingDropWorkItem = nil
    }

    private func applyPickupWindowScale(active: Bool) {
        guard let window else { return }

        let currentFrame = window.frame
        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)
        let factor = active ? pickupWindowScale : (1.0 / pickupWindowScale)

        let nextWidth = max(window.minSize.width, currentFrame.width * factor)
        let nextHeight = max(window.minSize.height, currentFrame.height * factor)
        let nextOrigin = NSPoint(x: center.x - (nextWidth / 2.0), y: center.y - (nextHeight / 2.0))
        let nextFrame = NSRect(origin: nextOrigin, size: NSSize(width: nextWidth, height: nextHeight))

        window.setFrame(nextFrame, display: true, animate: true)
    }

    private func hideCursorIfNeeded() {
        if cursorHidden { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursorIfNeeded() {
        if !cursorHidden { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func installScrollMonitorsIfNeeded() {
        if localScrollMonitor == nil {
            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return self.handleScrollMove(with: event, source: "local-monitor") ? nil : event
            }
        }

        if globalScrollMonitor == nil {
            globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                _ = self?.handleScrollMove(with: event, source: "global-monitor")
            }
        }
    }

    private func removeScrollMonitors() {
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }

        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }

    }

    private func installAppStateObserversIfNeeded() {
        if appDidResignActiveObserver == nil {
            appDidResignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resetPickupState(reason: "app-resign-active")
            }
        }
    }

    private func removeAppStateObservers() {
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
            self.appDidResignActiveObserver = nil
        }
    }

    private func resetPickupState(reason: String) {
        cancelPendingDrop()
        recentScrollSamples.removeAll(keepingCapacity: true)
        trackedTouches.removeAll()
        isDraggingWithScroll = false
        setPickup(active: false)
        mouseDragStartWindowFrame = nil
        mouseDragStartScreenPoint = nil
        lastCentroid = nil
        pinchBaseFrame = nil
        pinchBaseCenter = nil
        pinchAccumulatedScale = 1.0
        pinchHitMinDuringCurrentGesture = false
        pinchHitMaxDuringCurrentGesture = false
        displayLinkLock.lock()
        pendingScrollDelta = .zero
        displayLinkLock.unlock()
    }

    private func recordScrollSample(dx: CGFloat, dy: CGFloat) {
        let now = CACurrentMediaTime()
        let sample = ScrollSample(time: now, dx: dx, dy: dy)
        recentScrollSamples.append(sample)

        let minTime = now - SnapEngine.Config.velocityWindow
        recentScrollSamples.removeAll { $0.time < minTime }
    }

    private func maybeSnapWindowFromRecentSwipe(window: NSWindow) {
        guard !recentScrollSamples.isEmpty else { return }

        let now = CACurrentMediaTime()
        let minTime = now - SnapEngine.Config.velocityWindow
        let activeSamples = recentScrollSamples.filter { $0.time >= minTime }
        guard !activeSamples.isEmpty else { return }

        let elapsed = max(activeSamples.last!.time - activeSamples.first!.time, 0.016)
        let totalDX = activeSamples.reduce(CGFloat.zero) { $0 + $1.dx }
        let totalDY = activeSamples.reduce(CGFloat.zero) { $0 + $1.dy }
        let velocityX = totalDX / elapsed
        let velocityY = totalDY / elapsed

        snapAnimationInFlight = true
        recentScrollSamples.removeAll(keepingCapacity: true)
        snapEngine.animateSnap(window: window, velocityX: velocityX, velocityY: velocityY) { [weak self] in
            self?.snapAnimationInFlight = false
        }
    }
}

private struct ScrollSample {
    let time: CFTimeInterval
    let dx: CGFloat
    let dy: CGFloat
}

private struct SnapEngine {
    struct Config {
        static let cornerInset: CGFloat = 16
        static let velocityWindow: CFTimeInterval = 0.10
        static let overshootDistance: CGFloat = 8
        static let glideDuration: TimeInterval = 0.62
        static let settleDuration: TimeInterval = 0.52
    }

    private enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    func animateSnap(window: NSWindow, velocityX: CGFloat, velocityY: CGFloat, completion: @escaping () -> Void) {
        let visibleFrame = resolveVisibleFrame(for: window.frame)
        let corner = resolveCorner(
            velocityX: velocityX,
            velocityY: velocityY,
            currentFrame: window.frame,
            visibleFrame: visibleFrame
        )
        let targetFrame = targetFrame(for: window.frame, in: visibleFrame, corner: corner)
        let overshootFrame = overshootFrame(from: window.frame, target: targetFrame)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Config.glideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.90, 0.30, 1.0)
            window.animator().setFrame(overshootFrame, display: true)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Config.settleDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.88, 0.28, 1.0)
                window.animator().setFrame(targetFrame, display: true)
            } completionHandler: {
                completion()
            }
        }
    }

    private func resolveCorner(velocityX: CGFloat, velocityY: CGFloat, currentFrame: NSRect, visibleFrame: NSRect) -> Corner {
        let speed = max(hypot(velocityX, velocityY), 0.001)
        let swipeVector = NSPoint(x: velocityX / speed, y: velocityY / speed)
        let windowCenter = NSPoint(x: currentFrame.midX, y: currentFrame.midY)

        let cornerCenters: [(Corner, NSPoint)] = [
            (.topLeft, NSPoint(
                x: visibleFrame.minX + Config.cornerInset + (currentFrame.width / 2.0),
                y: visibleFrame.maxY - Config.cornerInset - (currentFrame.height / 2.0)
            )),
            (.topRight, NSPoint(
                x: visibleFrame.maxX - Config.cornerInset - (currentFrame.width / 2.0),
                y: visibleFrame.maxY - Config.cornerInset - (currentFrame.height / 2.0)
            )),
            (.bottomLeft, NSPoint(
                x: visibleFrame.minX + Config.cornerInset + (currentFrame.width / 2.0),
                y: visibleFrame.minY + Config.cornerInset + (currentFrame.height / 2.0)
            )),
            (.bottomRight, NSPoint(
                x: visibleFrame.maxX - Config.cornerInset - (currentFrame.width / 2.0),
                y: visibleFrame.minY + Config.cornerInset + (currentFrame.height / 2.0)
            ))
        ]

        var bestCorner: Corner = .bottomRight
        var bestScore: CGFloat = -.infinity

        for (corner, center) in cornerCenters {
            let vx = center.x - windowCenter.x
            let vy = center.y - windowCenter.y
            let length = max(hypot(vx, vy), 0.001)
            let directionToCorner = NSPoint(x: vx / length, y: vy / length)
            let dot = (directionToCorner.x * swipeVector.x) + (directionToCorner.y * swipeVector.y)

            if dot > bestScore {
                bestScore = dot
                bestCorner = corner
            }
        }

        return bestCorner
    }

    private func resolveVisibleFrame(for windowFrame: NSRect) -> NSRect {
        let windowCenter = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screens = NSScreen.screens

        if let direct = screens.first(where: { $0.visibleFrame.contains(windowCenter) }) {
            return direct.visibleFrame
        }

        return screens.min(by: {
            squaredDistance(from: windowCenter, to: $0.visibleFrame) <
            squaredDistance(from: windowCenter, to: $1.visibleFrame)
        })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? windowFrame
    }

    private func targetFrame(for currentFrame: NSRect, in visibleFrame: NSRect, corner: Corner) -> NSRect {
        let width = currentFrame.width
        let height = currentFrame.height
        let inset = Config.cornerInset

        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .topLeft:
            x = visibleFrame.minX + inset
            y = visibleFrame.maxY - height - inset
        case .topRight:
            x = visibleFrame.maxX - width - inset
            y = visibleFrame.maxY - height - inset
        case .bottomLeft:
            x = visibleFrame.minX + inset
            y = visibleFrame.minY + inset
        case .bottomRight:
            x = visibleFrame.maxX - width - inset
            y = visibleFrame.minY + inset
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func overshootFrame(from currentFrame: NSRect, target: NSRect) -> NSRect {
        var frame = target
        let dx = target.midX - currentFrame.midX
        let dy = target.midY - currentFrame.midY
        let distance = max(hypot(dx, dy), 0.001)
        frame.origin.x += (dx / distance) * Config.overshootDistance
        frame.origin.y += (dy / distance) * Config.overshootDistance
        return frame
    }


    private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return (dx * dx) + (dy * dy)
    }
}