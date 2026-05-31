//
//  floatyMPVApp.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI
import Cocoa

/// `AppDelegate` handles app lifecycle events, particularly graceful termination.
/// When the user quits from the dock or uses Cmd+Q, macOS sends a termination request.
/// This delegate ensures we clean up resources properly before exiting.
class AppDelegate: NSObject, NSApplicationDelegate {
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
@main
struct floatyMPVApp: App {
    /// Attach the AppDelegate to handle lifecycle events
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    /// The `body` property is the heart of the `App` protocol.
    /// It must return a `Scene`, which represents a distinct part of the app's user interface.
    ///
    /// The return type `some Scene` uses an opaque type, meaning the specific type
    /// is hidden, but it is guaranteed to conform to the `Scene` protocol.
    var body: some Scene {
        /// `WindowGroup` is a built-in SwiftUI scene that manages a set of windows
        /// with identical structure. When the app launches, it automatically
        /// creates and displays a window containing the `ContentView`.
        WindowGroup {
            ContentView()
        }
        /// `.windowResizability` is a scene modifier that restricts how a user
        /// can resize the window. Here, `.contentMinSize` ensures the window
        /// cannot be resized smaller than the minimum size defined within `ContentView`.
        .windowResizability(.contentMinSize)
    }
}
