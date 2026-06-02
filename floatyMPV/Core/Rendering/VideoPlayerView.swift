//
//  VideoPlayerView.swift
//  floatyMPV
//

import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var playerController: MPVController
    var isGestureMoving: Bool = false
    var isSnapAnimating: Bool = false

    func makeNSView(context: Context) -> VideoView {
        let view = VideoView(frame: .zero, playerController: playerController)
        playerController.mpvInitRendering(layer: view.videoLayer)
        view.videoLayer.isGestureMoving = isGestureMoving
        view.videoLayer.isSnapAnimating = isSnapAnimating
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        // Size updates and redraw requests are automatically handled by CAOpenGLLayer resizing masks.
        nsView.videoLayer.isGestureMoving = isGestureMoving
        nsView.videoLayer.isSnapAnimating = isSnapAnimating
    }

    static func dismantleNSView(_ nsView: VideoView, coordinator: ()) {
        nsView.playerController?.uninitRendering()
    }
}
