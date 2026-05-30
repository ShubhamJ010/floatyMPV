//
//  ContentView.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI

/// `ContentView` is the primary view of our application.
/// It conforms to the `View` protocol, which requires a `body` property
/// that returns a layout defined in SwiftUI's declarative syntax.
struct ContentView: View {
    /// `@State` is a property wrapper that tells SwiftUI to manage the storage
    /// of this property. When the value of `isPickedUp` changes, SwiftUI will
    /// automatically re-render the view hierarchy that depends on this value.
    /// It is declared as `private` because it is internal to `ContentView`.
    @State private var isPickedUp = false

    /// The `body` property defines the visual structure of the view.
    var body: some View {
        ZStack {
            /// `VisualEffectView` provides the hard Gaussian blur (material effect).
            /// We use `.hudWindow` for a strong, "hard" blur appearance.
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        /// `.shadow` adds visual depth. We change shadow parameters based on
        /// the `isPickedUp` state to create a "lifted" effect when interaction occurs.
        .shadow(
            color: .black.opacity(isPickedUp ? 0.45 : 0.15),
            radius: isPickedUp ? 30 : 10,
            y: isPickedUp ? 20 : 4
        )
        /// The `.background` modifier places `WindowAccessor` behind the card.
        .background(WindowAccessor())

        /// `.overlay` stacks `GestureSurface` on top of the card.
        .overlay(GestureSurface(isPickedUp: $isPickedUp))

        /// The `.frame` modifier sets constraints on the view's dimensions.
        .frame(
            minWidth: 280,
            idealWidth: 360,
            maxWidth: .infinity,
            minHeight: 180,
            idealHeight: 220,
            maxHeight: .infinity
        )
        /// `.animation` defines how the view transitions between states.
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: isPickedUp)
    }
}

/// A helper view that wraps `NSVisualEffectView` for macOS blur effects.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
