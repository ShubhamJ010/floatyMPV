//
//  floatyMPVApp.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI
import Cocoa

/// `AppDelegate` owns the application's window lifecycle.
///
/// The real window is a `FloatingPanel` (a custom `NSPanel` subclass that
/// opts out of the macOS Accessibility tree to stay invisible to Swish /
/// Magnet). It is created in `applicationDidFinishLaunching` once the
/// activation policy is set, then activated so the panel becomes the key
/// window and can receive drag-and-drop and keyboard input.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    /// Promotes the process to an accessory app before the first window is created.
    /// This removes the Dock icon and menu bar so the player behaves like the
    /// system PiP window (no Dock, no menu bar, not in Cmd+Tab).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Creates the `FloatingPanel`, hosts `ContentView` inside it, and
    /// activates the app so the panel is the key window. Without
    /// `NSApp.activate(ignoringOtherApps:)`, an `.accessory` app launches
    /// into the background and the OS never delivers `mouseDragged` /
    /// drop events to its views.
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MainWindowController()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when the app receives a quit request.
    /// Returning `true` allows the quit, `false` blocks it.
    /// We return `true` to allow termination after cleanup.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Called when the app is about to terminate.
    /// Returning `.terminateNow` allows immediate exit, `.terminateCancel` blocks it.
    /// We use this to ensure all cleanup is complete.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Allow the app to terminate; cleanup happens in controller deinit
        return .terminateNow
    }
}

/// The `@main` attribute signifies the entry point of the entire application.
/// It informs the Swift compiler that this struct (`floatyMPVApp`) is the starting
/// point for program execution, replacing the need for a traditional `main.swift` file.
///
/// The `App` protocol defines the structure and behavior of a SwiftUI application.
/// Every SwiftUI app must have a struct that conforms to this protocol.
///
/// `body` returns a `Settings` placeholder because the real window is
/// created by `AppDelegate` via `MainWindowController`. `Settings` does
/// not auto-open a window, so the app does not have a SwiftUI-managed
/// window competing with the `FloatingPanel`.
@main
struct floatyMPVApp: App {
    /// Attach the AppDelegate to handle lifecycle events
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
