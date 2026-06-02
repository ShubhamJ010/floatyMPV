//
//  ContentView.swift
//  floatyMPV
//
//  Created by Shubham Jha on 31/05/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// `ContentView` is the primary view of our application.
struct ContentView: View {
    @StateObject private var playerController = MPVController()
    @State private var isPickedUp = false
    @State private var isSnapAnimating = false
    @State private var isTargeted = false
    var body: some View {
        ZStack {
            /// `VisualEffectView` provides the hard Gaussian blur.
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                /// Subtle scale effect when targeted by a drop.
                .scaleEffect(isTargeted ? 1.02 : 1.0)
            
            if playerController.hasActiveFile {
                VideoPlayerView(
                    playerController: playerController,
                    isGestureMoving: isPickedUp,
                    isSnapAnimating: isSnapAnimating
                )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    /// Cosmetic Gaussian blur when the renderer is frozen.
                    ///
                    /// `ViewLayer.canDraw` returns `false` while `isGestureMoving` or
                    /// `isSnapAnimating` is true, so the last decoded frame stays on
                    /// screen with no new frames arriving. Softening that frozen frame
                    /// makes the freeze feel intentional — a settling visual — rather
                    /// than a glitch. SwiftUI composites the AppKit-rendered output
                    /// through this filter, so it does not touch the GL pipeline.
                    .blur(radius: (isPickedUp) ? 6 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isPickedUp)
                    .animation(.easeInOut(duration: 0.2), value: isSnapAnimating)
            } else {
                /// Visual indicator for the drop zone.
                DropZoneOverlay(isTargeted: isTargeted)
            }
        }
        /// `.shadow` adds visual depth.
        .shadow(
            color: .black.opacity(isPickedUp || isTargeted ? 0.45 : 0.15),
            radius: isPickedUp || isTargeted ? 30 : 10,
            y: isPickedUp || isTargeted ? 20 : 4
        )
        .overlay(
            GestureSurface(
                isPickedUp: $isPickedUp,
                isSnapAnimating: $isSnapAnimating,
                playerController: playerController
            )
        )
        .frame(
            minWidth: 280,
            idealWidth: 360,
            maxWidth: .infinity,
            minHeight: 180,
            idealHeight: 220,
            maxHeight: .infinity
        )
        /// Register as a drop destination for file URLs.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        /// Forward aspect-ratio changes to `MainWindowController`, which owns
        /// the `FloatingPanel` and applies the aspect-ratio lock + resize
        /// clamp. SwiftUI cannot reach the AppKit-owned panel directly.
        .onChange(of: playerController.videoAspectRatio) { _, newRatio in
            NotificationCenter.default.post(
                name: .videoAspectRatioChanged,
                object: nil,
                userInfo: [Notification.aspectRatioKey: newRatio]
            )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isPickedUp)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isTargeted)
    }

    /// Processes the dropped items and filters for .mp4 files.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        let pathExtension = url.pathExtension.lowercased()
                        // Support typical video formats mpv supports
                        let supportedExtensions = ["mp4", "mkv", "avi", "mov", "m4v", "flv"]
                        if supportedExtensions.contains(pathExtension) {
                            print("[DropZone] Accepted: \(url.path)")
                            DispatchQueue.main.async {
                                playerController.loadFile(path: url.path)
                            }
                        } else {
                            print("[DropZone] Rejected: \(url.path) (unsupported format)")
                        }
                    }
                }
            }
        }
        return true
    }
}
