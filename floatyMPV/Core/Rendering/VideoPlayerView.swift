//
//  VideoPlayerView.swift
//  floatyMPV
//

import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var playerController: MPVController

    func makeNSView(context: Context) -> VideoView {
        let view = VideoView(frame: .zero, playerController: playerController)
        playerController.mpvInitRendering(layer: view.videoLayer)
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        // Size updates and redraw requests are automatically handled by CAOpenGLLayer resizing masks.
    }
}
