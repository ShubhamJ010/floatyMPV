import AppKit
import SwiftUI

/// `MainWindowController` owns the application's single `FloatingPanel`
/// and hosts the SwiftUI `ContentView` inside it via `NSHostingController`.
///
/// Replaces the previous SwiftUI `WindowGroup { ContentView() }` setup,
/// which created a plain `NSWindow` whose accessibility tree Swish /
/// Magnet could drive. The real window now lives entirely in AppKit land
/// so we can subclass `NSPanel` and opt out of the accessibility tree.
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private var isApplyingResizeClamp = false

    convenience init() {
        let initialSize = NSSize(width: 360, height: 220)
        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: initialSize.width,
            height: initialSize.height
        )
        let panel = FloatingPanel(contentRect: initialRect, aspectRatio: 1.0)
        panel.setContentSize(initialSize)
        panel.center()

        self.init(window: panel)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: ContentView())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAspectRatioChanged(_:)),
            name: .videoAspectRatioChanged,
            object: nil
        )

        panel.makeKeyAndOrderFront(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Aspect ratio

    @objc private func handleAspectRatioChanged(_ note: Notification) {
        guard let raw = note.userInfo?[Notification.aspectRatioKey] as? CGFloat,
              raw > 0
        else { return }
        guard let panel = window as? FloatingPanel else { return }
        applyAspectRatio(raw, to: panel)
    }

    private func applyAspectRatio(_ aspectRatio: CGFloat, to panel: FloatingPanel) {
        panel.aspectRatio = NSSize(width: aspectRatio, height: 1.0)

        var frame = panel.frame
        let newWidth = frame.height * aspectRatio
        let clampedWidth = min(
            max(newWidth, FloatingPanel.minWindowSize.width),
            FloatingPanel.maxWindowSize.width
        )
        let newHeight = clampedWidth / aspectRatio
        let clampedHeight = min(
            max(newHeight, FloatingPanel.minWindowSize.height),
            FloatingPanel.maxWindowSize.height
        )
        frame.size = NSSize(width: clampedWidth, height: clampedHeight)
        frame.origin.x = frame.origin.x + (panel.frame.width - clampedWidth) / 2
        frame.origin.y = frame.origin.y + (panel.frame.height - clampedHeight) / 2
        panel.setFrame(frame, display: true, animate: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        // No-op — prevents print I/O during gesture-driven window movement
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        guard !isApplyingResizeClamp else { return }

        var nextFrame = panel.frame
        let clampedWidth = min(nextFrame.width, FloatingPanel.maxWindowSize.width)
        let clampedHeight = min(nextFrame.height, FloatingPanel.maxWindowSize.height)

        if clampedWidth != nextFrame.width || clampedHeight != nextFrame.height {
            isApplyingResizeClamp = true
            let center = NSPoint(x: nextFrame.midX, y: nextFrame.midY)
            nextFrame.size = NSSize(width: clampedWidth, height: clampedHeight)
            nextFrame.origin = NSPoint(
                x: center.x - (clampedWidth / 2.0),
                y: center.y - (clampedHeight / 2.0)
            )
            panel.setFrame(nextFrame, display: false, animate: false)
            isApplyingResizeClamp = false
        }
    }
}

extension Notification.Name {
    static let videoAspectRatioChanged = Notification.Name("floatyMPV.videoAspectRatioChanged")
}

extension Notification {
    static let aspectRatioKey = "aspectRatio"
}
