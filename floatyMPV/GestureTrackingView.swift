import AppKit

final class GestureTrackingView: NSView {
    var onPickedUpChanged: ((Bool) -> Void)?

    private var trackedTouches: [ObjectIdentifier: NSPoint] = [:]
    private var lastCentroid: NSPoint?
    private var pickupActive = false
    private var cursorHidden = false
    private var pinchBaseFrame: NSRect?
    private var pinchBaseCenter: NSPoint?
    private let pickupWindowScale: CGFloat = 1.08
    private var pendingDropWorkItem: DispatchWorkItem?
    private let pickupDropDebounce: TimeInterval = 0.08
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var appDidResignActiveObserver: Any?
    private var mouseDragStartWindowFrame: NSRect?
    private var mouseDragStartScreenPoint: NSPoint?

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
        print("[Gesture] Tracking surface initialized")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = [.indirect]
        acceptsTouchEvents = true
        wantsRestingTouches = true
        installScrollMonitorsIfNeeded()
        installAppStateObserversIfNeeded()
    }

    deinit {
        cancelPendingDrop()
        removeScrollMonitors()
        removeAppStateObservers()
        showCursorIfNeeded()
    }

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

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        mouseDragStartWindowFrame = window.frame
        mouseDragStartScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        setPickup(active: true)
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
        resetPickupState(reason: "mouse-up")
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard handleScrollMove(with: event, source: "local-view") else {
            super.scrollWheel(with: event)
            return
        }
    }

    private func handleScrollMove(with event: NSEvent, source: String) -> Bool {
        guard let window else {
            return false
        }

        if !NSApp.isActive && source == "global-monitor" && !pickupActive {
            let cursorPoint = NSEvent.mouseLocation
            guard window.frame.contains(cursorPoint) else {
                return false
            }
            setPickup(active: true)
        }

        guard pickupActive else {
            return false
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetPickupState(reason: "phase-end-\(source)")
            print("[Gesture] Pickup released by phase end from \(source)")
            return true
        }

        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale

        if abs(dx) < 0.01 && abs(dy) < 0.01 { return true }

        var nextFrame = window.frame
        nextFrame.origin.x += dx
        nextFrame.origin.y -= dy
        window.setFrame(nextFrame, display: false, animate: false)

        let kind = event.momentumPhase.isEmpty ? "Two-finger" : "Momentum"
        print("[Gesture] \(kind) move [\(source)] delta: (\(dx), \(-dy)) frame: \(window.frame)")
        return true
    }

    override func smartMagnify(with event: NSEvent) {
        guard let window else { return }
        window.zoom(nil)
        print("[Gesture] Smart magnify: toggled maximize/restore")
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }

        if pinchBaseFrame == nil {
            pinchBaseFrame = window.frame
            pinchBaseCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
            print("[Gesture] Pinch resize started")
        }

        guard let baseFrame = pinchBaseFrame, let baseCenter = pinchBaseCenter else { return }

        let minWidth = max(window.minSize.width, 220)
        let minHeight = max(window.minSize.height, 140)
        let maxWidth: CGFloat = 1200
        let maxHeight: CGFloat = 900
        let scale = max(0.65, min(1.8, 1.0 + event.magnification))

        let nextWidth = max(minWidth, min(maxWidth, baseFrame.width * scale))
        let nextHeight = max(minHeight, min(maxHeight, baseFrame.height * scale))
        let nextOrigin = NSPoint(x: baseCenter.x - (nextWidth / 2.0), y: baseCenter.y - (nextHeight / 2.0))
        let nextFrame = NSRect(origin: nextOrigin, size: NSSize(width: nextWidth, height: nextHeight))

        window.setFrame(nextFrame, display: true, animate: false)
        print("[Gesture] Pinch resize frame: \(window.frame)")
    }

    override func endGesture(with event: NSEvent) {
        pinchBaseFrame = nil
        pinchBaseCenter = nil
        print("[Gesture] Gesture sequence ended")
        super.endGesture(with: event)
    }

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
            if lastCentroid == nil {
                print("[Gesture] Two-finger contact started")
            }
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
        applyPickupWindowScale(active: active)
        if active {
            hideCursorIfNeeded()
        } else {
            showCursorIfNeeded()
        }
        onPickedUpChanged?(active)
        print("[Gesture] Pickup state: \(active ? "active" : "inactive")")
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
        print("[Gesture] Cursor hidden")
    }

    private func showCursorIfNeeded() {
        if !cursorHidden { return }
        NSCursor.unhide()
        cursorHidden = false
        print("[Gesture] Cursor shown")
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
        trackedTouches.removeAll()
        setPickup(active: false)
        mouseDragStartWindowFrame = nil
        mouseDragStartScreenPoint = nil
        lastCentroid = nil
        pinchBaseFrame = nil
        pinchBaseCenter = nil
        print("[Gesture] Reset pickup state: \(reason)")
    }
}
