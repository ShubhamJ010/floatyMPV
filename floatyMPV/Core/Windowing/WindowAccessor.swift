import AppKit
import SwiftUI

/// `WindowAccessor` is a `NSViewRepresentable` bridge used to access and configure
/// the underlying macOS `NSWindow` object, providing fine-grained control
/// over the window style (borderless, floating, etc.) that pure SwiftUI cannot offer.
struct WindowAccessor: NSViewRepresentable {
    static let minWindowSize = NSSize(width: 280, height: 180)

    let aspectRatio: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        /// We use `DispatchQueue.main.async` because the `NSWindow` might not
        /// be immediately available upon the initialization of the `NSView`.
        DispatchQueue.main.async {
            guard let window = view.window else {
                print("[Window] Unable to access NSWindow yet")
                return
            }
            context.coordinator.configure(window: window, aspectRatio: aspectRatio)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.configure(window: window, aspectRatio: aspectRatio)
        }
    }

    /// `makeCoordinator` creates a delegate object (`Coordinator`) to handle
    /// `NSWindow` events (e.g., resizing, moving).
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// The `Coordinator` acts as the `NSWindowDelegate`, bridging AppKit
    /// window events into our application logic.
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var configuredWindow: NSWindow?
        private var isApplyingResizeClamp = false
        private var currentAspectRatio: CGFloat = 1.0

        /// Configures the `NSWindow` with specific styling needed for a PiP-style window.
        func configure(window: NSWindow, aspectRatio: CGFloat) {
            let isNew = configuredWindow !== window
            if isNew {
                configuredWindow = window
                window.delegate = self
                window.styleMask = [.borderless, .resizable]
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.hasShadow = true
                window.backgroundColor = .clear
                window.isOpaque = false
                window.level = .floating
                window.isMovableByWindowBackground = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.minSize = WindowAccessor.minWindowSize

                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.layer?.masksToBounds = true
                    contentView.layer?.cornerRadius = 16
                }
            }

            /// Apply aspect ratio constraint when the video aspect ratio changes.
            if abs(currentAspectRatio - aspectRatio) > 0.001 {
                currentAspectRatio = aspectRatio
                window.aspectRatio = NSSize(width: aspectRatio, height: 1.0)

                var frame = window.frame
                let newWidth = frame.height * aspectRatio
                let clampedWidth = min(max(newWidth, WindowAccessor.minWindowSize.width), 589)
                let newHeight = clampedWidth / aspectRatio
                let clampedHeight = min(max(newHeight, WindowAccessor.minWindowSize.height), 360)
                frame.size = NSSize(width: clampedWidth, height: clampedHeight)
                frame.origin.x = frame.origin.x + (window.frame.width - clampedWidth) / 2
                frame.origin.y = frame.origin.y + (window.frame.height - clampedHeight) / 2
                window.setFrame(frame, display: true, animate: true)
            }
        }

        func windowDidMove(_ notification: Notification) {
            // No-op — prevents print I/O during gesture-driven window movement
        }

        func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            guard !isApplyingResizeClamp else { return }

            var nextFrame = window.frame

            // Clamp to max bounds, keeping center stable.
            // Use a small tolerance to avoid fighting with gesture setFrame calls.
            let clampedWidth = min(nextFrame.width, 589)
            let clampedHeight = min(nextFrame.height, 360)

            if clampedWidth != nextFrame.width || clampedHeight != nextFrame.height {
                isApplyingResizeClamp = true
                let center = NSPoint(x: nextFrame.midX, y: nextFrame.midY)
                nextFrame.size = NSSize(width: clampedWidth, height: clampedHeight)
                nextFrame.origin = NSPoint(
                    x: center.x - (clampedWidth / 2.0),
                    y: center.y - (clampedHeight / 2.0)
                )
                window.setFrame(nextFrame, display: false, animate: false)
                isApplyingResizeClamp = false
            }
        }
    }
}
