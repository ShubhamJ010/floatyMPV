//
//  VideoView.swift
//  floatyMPV
//

import Cocoa

class VideoView: NSView {
    weak var playerController: MPVController?

    lazy var videoLayer: ViewLayer = {
        let layer = ViewLayer(self)
        return layer
    }()

    init(frame: CGRect, playerController: MPVController) {
        self.playerController = playerController
        super.init(frame: frame)

        self.layer = videoLayer
        self.wantsLayer = true
        self.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawing is fully handled by OpenGL layer.
    }
}
