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

    /// Mirrors `GestureTrackingView.onSnapAnimatingChanged` into SwiftUI so
    /// the renderer layer can suspend drawing during the corner-snap glide.
    @Binding var isSnapAnimating: Bool

    /// The playback controller passed through for keyboard shortcut dispatch.
    let playerController: MPVController

    /// `makeNSView` is called by SwiftUI once to create the `NSView` instance.
    /// This is where we instantiate our custom AppKit view.
    func makeNSView(context: Context) -> GestureTrackingView {
        let view = GestureTrackingView()
        view.playerController = playerController
        attachClosures(to: view)
        return view
    }

    /// `updateNSView` is called by SwiftUI whenever the state of the SwiftUI
    /// view changes. It allows us to keep the underlying `NSView` in sync
    /// with the SwiftUI state.
    func updateNSView(_ nsView: GestureTrackingView, context: Context) {
        nsView.playerController = playerController
        attachClosures(to: nsView)
    }

    /// Wires up the AppKit → SwiftUI callbacks. All state mutations are
    /// dispatched to the main thread to satisfy SwiftUI's thread safety
    /// requirements.
    private func attachClosures(to view: GestureTrackingView) {
        view.onPickedUpChanged = { pickedUp in
            DispatchQueue.main.async {
                isPickedUp = pickedUp
            }
        }
        view.onSnapAnimatingChanged = { animating in
            DispatchQueue.main.async {
                isSnapAnimating = animating
            }
        }
    }
}
