//
//  ContentView.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isPickedUp = false

    var body: some View {
        PrototypeCardView(isPickedUp: isPickedUp)
            .background(WindowAccessor())
            .overlay(GestureSurface(isPickedUp: $isPickedUp))
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

private struct PrototypeCardView: View {
    let isPickedUp: Bool

    var body: some View {
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
        .shadow(
            color: .black.opacity(isPickedUp ? 0.68 : 0.2),
            radius: isPickedUp ? 40 : 10,
            y: isPickedUp ? 30 : 4
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: isPickedUp)
    }
}
