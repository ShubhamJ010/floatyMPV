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
    @State private var isTargeted = false
    @State private var videoLoaded = false
    var body: some View {
        ZStack {
            /// `VisualEffectView` provides the hard Gaussian blur.
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                /// Subtle scale effect when targeted by a drop.
                .scaleEffect(isTargeted ? 1.02 : 1.0)
            
            if videoLoaded {
                VideoPlayerView(playerController: playerController)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .background(WindowAccessor(aspectRatio: playerController.videoAspectRatio))
        .overlay(GestureSurface(isPickedUp: $isPickedUp))
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
                                videoLoaded = true
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

/// A visual overlay that appears when dragging a file over the window.
private struct DropZoneOverlay: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(isTargeted ? .primary : .secondary)
                .scaleEffect(isTargeted ? 1.1 : 0.9)
            
            Text(isTargeted ? "Drop to Play Video" : "Drop Video Here")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isTargeted ? .primary : .secondary)
        }
        .opacity(isTargeted ? 1.0 : 0.4)
        .blur(radius: isTargeted ? 0 : 0.5)
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

