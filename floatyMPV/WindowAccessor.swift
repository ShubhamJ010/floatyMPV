import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var configuredWindow: NSWindow?

        func configure(window: NSWindow) {
            if configuredWindow === window { return }
            configuredWindow = window

            window.delegate = self
            window.styleMask = [.borderless, .resizable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.hasShadow = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 280, height: 180)
            window.setFrame(window.frame, display: true)

            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.masksToBounds = true
                contentView.layer?.cornerRadius = 16
            }

            print("[Window] Configured borderless floating PiP window")
            print("[Window] Frame: \(window.frame)")
            print("[Window] Level: \(window.level.rawValue), Collection: \(window.collectionBehavior.rawValue)")
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
