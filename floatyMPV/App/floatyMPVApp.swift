//
//  floatyMPVApp.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI

/// The `@main` attribute signifies the entry point of the entire application.
/// It informs the Swift compiler that this struct (`floatyMPVApp`) is the starting
/// point for program execution, replacing the need for a traditional `main.swift` file.
///
/// The `App` protocol defines the structure and behavior of a SwiftUI application.
/// Every SwiftUI app must have a struct that conforms to this protocol.
@main
struct floatyMPVApp: App {
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
