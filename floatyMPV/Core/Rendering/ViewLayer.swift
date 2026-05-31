//
//  ViewLayer.swift
//  floatyMPV
//

import Cocoa
import QuartzCore
import OpenGL.GL
import OpenGL.GL3

class ViewLayer: CAOpenGLLayer {
    private weak var videoView: VideoView!
    private let mpvGLQueue = DispatchQueue(label: "com.floatympv.mpvgl", qos: .userInteractive)

    private var bufferDepth: GLint = 8
    private let cglContext: CGLContextObj
    private let cglPixelFormat: CGLPixelFormatObj
    private var fbo: GLint = 1

    @Atomic private var forceDraw = false
    @Atomic var inLiveResize: Bool = false {
        didSet {
            if inLiveResize {
                mpvGLQueue.async { [weak self] in
                    self?.update(force: true)
                }
            }
        }
    }

    init(_ videoView: VideoView) {
        self.videoView = videoView

        // Select pixel format
        var pix: CGLPixelFormatObj?
        var npix: GLint = 0
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            CGLPixelFormatAttribute(0)
        ]
        CGLChoosePixelFormat(attributes, &pix, &npix)
        guard let pixelFormat = pix else {
            fatalError("Cannot create CGLPixelFormatObj")
        }
        self.cglPixelFormat = pixelFormat

        // Create context
        var ctx: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &ctx)
        guard let context = ctx else {
            fatalError("Cannot create CGLContextObj")
        }
        self.cglContext = context

        // Sync to vertical retrace
        var i: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &i)
        CGLEnable(context, kCGLCEMPEngine)
        CGLSetCurrentContext(context)

        super.init()
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor
    }

    override init(layer: Any) {
        let previousLayer = layer as! ViewLayer
        self.videoView = previousLayer.videoView
        self.cglPixelFormat = previousLayer.cglPixelFormat
        self.cglContext = previousLayer.cglContext
        super.init(layer: layer)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(force: Bool = false) {
        if force {
            forceDraw = true
        }
        // Always schedule display — canDraw() gates via shouldRenderUpdateFrame().
        // The mpv update callback ensures we only draw when there's a new frame.
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsDisplay()
        }
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        guard let controller = videoView?.playerController else { return false }
        let shouldDraw = forceDraw || controller.shouldRenderUpdateFrame()
        return shouldDraw
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        forceDraw = false
        guard let controller = videoView?.playerController else { return }

        var i: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &i)
        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)

        // Skip rendering for degenerate viewport dimensions
        guard dims[2] > 0 && dims[3] > 0 else { return }

        var flip: CInt = 1

        if let context = controller.mpvRenderContext {
            fbo = i != 0 ? i : fbo
            var data = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(dims[2]), h: Int32(dims[3]), internal_format: 0)

            withUnsafeMutablePointer(to: &data) { dataPtr in
                withUnsafeMutablePointer(to: &flip) { flipPtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(dataPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: UnsafeMutableRawPointer(&bufferDepth)),
                        mpv_render_param()
                    ]
                    controller.lockAndSetOpenGLContext()
                    mpv_render_context_render(context, &params)
                    controller.unlockOpenGLContext()
                }
            }
        }

        // Use glFlush instead of glFinish — glFinish blocks until the GPU
        // completes, causing jitter. glFlush just submits the command buffer.
        glFlush()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        return cglPixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        return cglContext
    }
}