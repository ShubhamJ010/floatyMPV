//
//  ViewLayer.swift
//  floatyMPV
//

import Cocoa
import QuartzCore
import OpenGL.GL
import OpenGL.GL3

/// `ViewLayer` is the **only place** where OpenGL and mpv's renderer meet.
///
/// It subclasses `CAOpenGLLayer`, which is Apple's bridge between:
///   - **Core Animation** (the macOS compositor that owns rounded corners,
///     drop shadows, alpha blending, and the layer tree), and
///   - **OpenGL** (the GPU API libmpv uses to upload and draw video frames).
///
/// In plain terms: this layer is the "screen" libmpv paints onto, and it is
/// also the thing macOS composites into the transparent floating window.
///
/// Ownership rules:
///   - Rendering owns OpenGL context lifecycle (pixel format + context creation).
///   - Rendering owns the draw gating (`canDraw` → `draw`).
///   - Rendering MUST NOT know about keyboard shortcuts, drag math, or snap logic.
class ViewLayer: CAOpenGLLayer {
    /// Back-reference to the `VideoView` that owns this layer.
    /// Weak to avoid a retain cycle: `ViewLayer` → `videoView` → `videoLayer`.
    private weak var videoView: VideoView!

    /// Serial queue used only when we need to mutate `self` from a background
    /// thread (e.g. `inLiveResize` setter). Rendering itself happens on the
    /// thread that calls `draw(inCGLContext:)`, which CalAnimation manages.
    private let mpvGLQueue = DispatchQueue(label: "com.floatympv.mpvgl", qos: .userInteractive)

    // MARK: - OpenGL State

    /// Pixel buffer depth (8 bits per channel = 256 levels). Passed to libmpv
    /// via `MPV_RENDER_PARAM_DEPTH` so it allocates GL resources correctly.
    private var bufferDepth: GLint = 8

    /// The actual macOS OpenGL context (CGLContextObj). Created once in `init`
    /// and reused for every draw. macOS requires this to be "current" on the
    /// thread that issues GL commands.
    private let cglContext: CGLContextObj

    /// Pixel format descriptor for `cglContext`. Tells macOS what color depth,
    /// buffering, and OpenGL profile version to use.
    private let cglPixelFormat: CGLPixelFormatObj

    /// Framebuffer Object (FBO) id. The FBO is an OpenGL object that represents
    /// the pixel target. We do not create the FBO — the system compositor does —
    /// we read its id inside `draw(...)` and hand it to libmpv so frames land
    /// in the right place.
    private var fbo: GLint = 1

    // MARK: - Frame Gating State

    /// When `true`, the next `canDraw(...)` returns true immediately so we
    /// force a paint after `update(force: true)` (used during live resize).
    @Atomic private var forceDraw = false

    /// Tracks whether the window is currently being moved via gesture.
    /// When true, we temporarily suspend rendering to eliminate lock contention.
    @Atomic var isGestureMoving = false

    /// Tracks whether the window is mid-resize. While live-resizing we push
    /// redraws aggressively so the video does not freeze at the wrong size.
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

        // Configure the OpenGL "canvas" that macOS will use for this layer.
        //
        // 1. Pixel format:
        //    - `kCGLOGLPVersion_3_2_Core`: OpenGL 3.2 Core Profile (minimal modern set).
        //    - `kCGLPFAAccelerated`: GPU-backed, not software.
        //    - `kCGLPFADoubleBuffer`: two buffers (front+back) so one is shown
        //      while the next is painted, eliminating tearing.
        //
        // 2. Context: created from that pixel format. Shared with no other context
        //    (nil) because this is the only GL consumer.
        //
        // 3. Swap interval = 1: synchronize buffer swaps to vsync so motion
        //    is smooth and does not tear. `kCGLCEMPEngine`: enables the OpenGL
        //    multithreading engine on modern Macs (mostly a no-op for us since
        //    we serialize through a single context).
        //
        // 4. We call `CGLSetCurrentContext(context)` so any OpenGL calls made
        //    BEFORE the context is shipped to the main thread (there should not
        //    be any) share the same state.

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

    /// Called by Core Animation when the layer tree needs to copy an existing
    /// layer (e.g. during layer-backed view animations or layer migration).
    /// We forward the OpenGL objects (pixel format + context) so the new layer
    /// shares the same render target — there should only ever be one ViewLayer.
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

    deinit {
        // Release OpenGL resources when the layer is deallocated.
        // This ensures proper cleanup even when the app quits from the dock.
        CGLReleasePixelFormat(cglPixelFormat)
        CGLReleaseContext(cglContext)
    }

    /// Request a redraw on the next vsync-aligned frame.
    ///
    /// - `force == true`: sets the `forceDraw` flag so `canDraw` returns true
    ///   unconditionally. Used during live resize so the video does not lag.
    /// - Otherwise, libmpv's update callback decides whether redrawing is needed.
    ///
    /// We dispatch to the main queue because `setNeedsDisplay()` is a Core
    /// Animation method and must be called on the main thread.
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

    /// `CAOpenGLLayer` calls this at vsync to ask "should we draw this frame?"
    ///
    /// Return `true` to grant one draw call; `false` skips it and saves GPU work.
    ///
    /// We draw when either:
    ///   - A forced draw is pending (live resize, launch, etc.), or
    ///   - `shouldRenderUpdateFrame()` reports a new decoded frame from libmpv.
    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj, forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        if isGestureMoving {
            return false
        }
        guard let controller = videoView?.playerController else { return false }
        let shouldDraw = forceDraw || controller.shouldRenderUpdateFrame()
        return shouldDraw
    }

    /// The actual paint routine called by Core Animation at vsync.
    ///
    /// What happens here:
    ///   1. Query the current OpenGL framebuffer and viewport dimensions
    ///      (these are provided by the compositor; we did not create them).
    ///   2. Build an `mpv_opengl_fbo` struct describing that framebuffer to libmpv.
    ///   3. Lock the OpenGL context (make it current on this thread).
    ///   4. Call `mpv_render_context_render(...)` — libmpv uploads the new frame
    ///      and draws it into the FBO we described.
    ///   5. Unlock the context.
    ///   6. Call `glFlush()` to submit work to the GPU (non-blocking).
    ///
    /// Why `glFlush()` not `glFinish()`?
    ///   - `glFinish` blocks until every GPU command is complete — causes jitter.
    ///   - `glFlush` tells the GPU "start processing now.” The compositor handles
    ///     presenting the result at vsync, so we return immediately.
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