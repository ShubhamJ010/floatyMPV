import AppKit
import SwiftUI

/// `WindowAccessor` is a `NSViewRepresentable` bridge used to access and configure
/// the underlying macOS `NSWindow` object, providing fine-grained control
/// over the window style (borderless, floating, etc.) that pure SwiftUI cannot offer.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        /// We use `DispatchQueue.main.async` because the `NSWindow` might not
        /// be immediately available upon the initialization of the `NSView`.
        DispatchQueue.main.async {
            guard let window = view.window else {
                print("[Window] Unable to access NSWindow yet")
                return
            }
            context.coordinator.configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.configure(window: window)
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

        /// Configures the `NSWindow` with specific styling needed for a PiP-style window.
        func configure(window: NSWindow) {
            if configuredWindow === window { return }
            configuredWindow = window

            window.delegate = self
            /// `styleMask = [.borderless, .resizable]` removes the default title bar
            /// and borders, making the window fully customizable.
            window.styleMask = [.borderless, .resizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.hasShadow = true
            window.backgroundColor = .clear
            window.isOpaque = false
            /// `level = .floating` keeps the window on top of other applications.
            window.level = .floating
            window.isMovableByWindowBackground = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 280, height: 180)
            window.setFrame(window.frame, display: true)

            /// Configuring the underlying layer for rounded corners.
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.masksToBounds = true
                contentView.layer?.cornerRadius = 16
            }

            print("[Window] Configured borderless floating PiP window")
        }

        func windowDidMove(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            print("[Window] Did move to origin: \(window.frame.origin)")
        }

        func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            print("[Window] Did resize to: \(window.frame.size)")
        }
    }
}
