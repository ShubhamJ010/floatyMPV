import SwiftUI

/// `GestureSurface` acts as a bridge between SwiftUI and AppKit,
/// conforming to the `NSViewRepresentable` protocol.
///
/// SwiftUI does not natively support advanced AppKit mouse/touch event tracking,
/// so we create an `NSView` (AppKit) and wrap it in a SwiftUI view.
struct GestureSurface: NSViewRepresentable {
    /// `@Binding` is used to create a reference to a state managed elsewhere
    /// (in `ContentView`). This allows this view to read and write to the
    /// `isPickedUp` state in `ContentView` without owning it.
    @Binding var isPickedUp: Bool

    /// The playback controller passed through for keyboard shortcut dispatch.
    let playerController: MPVController

    /// `makeNSView` is called by SwiftUI once to create the `NSView` instance.
    /// This is where we instantiate our custom AppKit view.
    func makeNSView(context: Context) -> GestureTrackingView {
        let view = GestureTrackingView()
        view.playerController = playerController

        /// We define a closure (`onPickedUpChanged`) to receive callbacks
        /// from the AppKit view when the pickup state changes.
        view.onPickedUpChanged = { pickedUp in
            /// `DispatchQueue.main.async` ensures that updates to the
            /// `@Binding` state happen on the main thread, which is required
            /// for UI updates in SwiftUI to avoid thread-safety issues.
            DispatchQueue.main.async {
                isPickedUp = pickedUp
            }
        }
        return view
    }

    /// `updateNSView` is called by SwiftUI whenever the state of the SwiftUI
    /// view changes. It allows us to keep the underlying `NSView` in sync
    /// with the SwiftUI state.
    func updateNSView(_ nsView: GestureTrackingView, context: Context) {
        nsView.playerController = playerController
        nsView.onPickedUpChanged = { pickedUp in
            DispatchQueue.main.async {
                isPickedUp = pickedUp
            }
        }
    }
}
