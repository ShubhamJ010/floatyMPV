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
        PrototypeCardView(isPickedUp: isPickedUp)
            /// The `.background` modifier places `WindowAccessor` behind the card.
            /// `WindowAccessor` is a custom view that hooks into the underlying
            /// NSWindow to modify AppKit settings not available in pure SwiftUI.
            .background(WindowAccessor())

            /// `.overlay` stacks `GestureSurface` on top of the card.
            /// By passing `$isPickedUp`, we provide a `Binding`. A binding
            /// acts as a two-way connection: `GestureSurface` can read and modify
            /// the `isPickedUp` state in `ContentView`.
            .overlay(GestureSurface(isPickedUp: $isPickedUp))

            /// The `.frame` modifier sets constraints on the view's dimensions.
            /// It is crucial for AppKit/macOS apps to have explicit sizing
            /// constraints so the window layout engine knows how to behave.
            .frame(
                minWidth: 280,
                idealWidth: 360,
                maxWidth: .infinity,
                minHeight: 180,
                idealHeight: 220,
                maxHeight: .infinity
            )
    }
}

/// A private helper view that displays the visual representation of the "card".
/// Using small, encapsulated views helps keep the codebase modular and readable.
private struct PrototypeCardView: View {
    /// A regular `let` property indicates that this value is immutable
    /// once the view is initialized.
    let isPickedUp: Bool

    var body: some View {
        /// `ZStack` allows us to layer views on top of each other.
        /// The first element is at the bottom, and subsequent elements are layered above it.
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.75))

            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.white)

                Text("floatyMPV PiP Prototype")
                    .foregroundStyle(.white)
                    .font(.headline)

                Text("Drag anywhere. Resize from edges.")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.caption)
            }
            .padding(16)
        }
        /// `.shadow` adds visual depth. We change shadow parameters based on
        /// the `isPickedUp` state to create a "lifted" effect when interaction occurs.
        .shadow(
            color: .black.opacity(isPickedUp ? 0.68 : 0.2),
            radius: isPickedUp ? 40 : 10,
            y: isPickedUp ? 30 : 4
        )
        /// `.animation` defines how the view transitions between states.
        /// Here, we use a spring animation for a smooth, physical feel
        /// when `isPickedUp` changes.
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: isPickedUp)
    }
}
