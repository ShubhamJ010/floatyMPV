//
//  MPVController.swift
//  floatyMPV
//

import Cocoa
import Foundation
import Combine

class MPVController: NSObject, ObservableObject {
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var isPaused: Bool = true
    @Published var volume: Double = 100.0
    @Published var playbackSpeed: Double = 1.0
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0

    var videoAspectRatio: CGFloat {
        guard videoWidth > 0, videoHeight > 0 else { return 1.0 }
        return CGFloat(videoWidth) / CGFloat(videoHeight)
    }

    var mpv: OpaquePointer!
    var mpvRenderContext: OpaquePointer?
    private var openGLContext: CGLContextObj! = nil

    private lazy var queue = DispatchQueue(label: "com.floatympv.controller", qos: .userInteractive)

    override init() {
        super.init()
        mpvInit()
    }

    deinit {
        mpvUninitRendering()
    }

    func mpvInit() {
        mpv = mpv_create()
        guard mpv != nil else {
            print("Failed to create mpv instance")
            return
        }

        // Configure basic options
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "hwdec", "auto") // VideoToolbox hardware decoding on Mac

        // Energy-efficient quality for floaty window
        mpv_set_option_string(mpv, "vd-lavc-threads", "0")        // auto decode threads
        mpv_set_option_string(mpv, "opengl-pbo", "yes")           // faster uploads
        mpv_set_option_string(mpv, "opengl-glfinish", "no")       // non-blocking
        mpv_set_option_string(mpv, "framedrop", "vo")             // drop render frames
        mpv_set_option_string(mpv, "video-reversal-buffer", "disabled")
        mpv_set_option_string(mpv, "vd-lavc-fast", "yes")        // fast decode hacks
        mpv_set_option_string(mpv, "vd-lavc-skiploopfilter", "nonref") // skip non-ref frames
        mpv_set_option_string(mpv, "scale", "bilinear")           // cheap scaling
        mpv_set_option_string(mpv, "dscale", "bilinear")
        mpv_set_option_string(mpv, "cscale", "bilinear")
        mpv_set_option_string(mpv, "scale-antiring", "0.0")       // no antiring cost
        mpv_set_option_string(mpv, "correct-downscaling", "no")   // skip correction passes
        mpv_set_option_string(mpv, "linear-downscaling", "no")
        mpv_set_option_string(mpv, "linear-upscaling", "no")
        mpv_set_option_string(mpv, "video-latency-hacks", "yes")  // lower decode latency

        // Set a custom function that should be called when there are new events.
        mpv_set_wakeup_callback(mpv, { (ctx) in
            guard let ctx = ctx else { return }
            let controller = unsafeBitCast(ctx, to: MPVController.self)
            controller.readEvents()
        }, mutableRawPointerOf(obj: self))

        // Initialize mpv core
        let err = mpv_initialize(mpv)
        if err < 0 {
            print("Failed to initialize mpv: \(String(cString: mpv_error_string(err)))")
        }

        // Observe essential properties
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "dheight", MPV_FORMAT_INT64)
    }

    /// Call this when the window size changes to adapt video quality.
    /// Sets the output window size so mpv renders at the appropriate resolution.
    func updateWindowSize(width: Int, height: Int) {
        guard let mpv = mpv else { return }
        var w = Int32(clamping: width)
        var h = Int32(clamping: height)
        // Tell mpv the target rendering size so it can optimize decoding
        mpv_set_property(mpv, "window-width", MPV_FORMAT_INT64, &w)
        mpv_set_property(mpv, "window-height", MPV_FORMAT_INT64, &h)
        // Use vo as the hint for output size — helps mpv select appropriate quality
        mpv_set_option_string(mpv, "vo", "libmpv")
    }

    func mpvInitRendering(layer: ViewLayer) {
        guard let mpv = mpv else {
            fatalError("mpvInitRendering() should be called after mpv handle being initialized!")
        }

        let apiType = UnsafeMutableRawPointer(mutating: ("opengl" as NSString).utf8String)
        var openGLInitParams = mpv_opengl_init_params(
            get_proc_address: mpvGetOpenGLFunc,
            get_proc_address_ctx: nil
        )

        withUnsafeMutablePointer(to: &openGLInitParams) { openGLInitParams in
            var advanced: CInt = 1
            withUnsafeMutablePointer(to: &advanced) { advanced in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: openGLInitParams),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
                    mpv_render_param()
                ]
                let err = mpv_render_context_create(&mpvRenderContext, mpv, &params)
                if err < 0 {
                    print("Failed to create mpv render context: \(String(cString: mpv_error_string(err)))")
                }
            }
        }

        openGLContext = CGLGetCurrentContext()
        mpv_render_context_set_update_callback(
            mpvRenderContext!,
            mpvUpdateCallback,
            mutableRawPointerOf(obj: layer)
        )
    }

    func lockAndSetOpenGLContext() {
        if let context = openGLContext {
            CGLLockContext(context)
            CGLSetCurrentContext(context)
        }
    }

    func unlockOpenGLContext() {
        if let context = openGLContext {
            CGLUnlockContext(context)
        }
    }

    func mpvUninitRendering() {
        guard let context = mpvRenderContext else { return }
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
        mpvRenderContext = nil

        if mpv != nil {
            mpv_destroy(mpv)
            mpv = nil
        }
    }

    func shouldRenderUpdateFrame() -> Bool {
        guard let context = mpvRenderContext else { return false }
        let flags = mpv_render_context_update(context)
        return (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) > 0
    }

    // Helper to send arbitrary commands to mpv
    func mpvCommand(_ args: [String]) {
        guard let mpv = mpv else { return }
        var cArgs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs {
                if let ptr = ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }
        mpv_command(mpv, &cArgs)
    }

    // Load file command
    func loadFile(path: String) {
        mpvCommand(["loadfile", path])
    }

    func togglePause() {
        var flag: CInt = isPaused ? 0 : 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to seconds: Double) {
        let secondsStr = String(seconds)
        mpvCommand(["seek", secondsStr, "absolute"])
    }

    func setVolume(to val: Double) {
        var v = val
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v)
    }

    func seekRelative(_ seconds: Double) {
        mpvCommand(["seek", String(seconds), "relative"])
    }

    func setSpeed(_ rate: Double) {
        var r = rate
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &r)
    }

    func addVolume(_ delta: Double) {
        mpvCommand(["add", "volume", String(delta)])
    }

    func frameStep() {
        mpvCommand(["frame-step"])
    }

    func frameBackStep() {
        mpvCommand(["frame-back-step"])
    }

    func screenshot() {
        mpvCommand(["screenshot", "video"])
    }

    func playlistNext() {
        mpvCommand(["playlist-next"])
    }

    func playlistPrevious() {
        mpvCommand(["playlist-prev"])
    }

    func stop() {
        mpvCommand(["stop"])
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self = self, let mpv = self.mpv else { return }
            while true {
                let event = mpv_wait_event(mpv, 0)!
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE {
                    break
                }
                self.handleEvent(event)
                if eventId == MPV_EVENT_SHUTDOWN {
                    break
                }
            }
        }
    }

    private func handleEvent(_ event: UnsafePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: prop.name)
            if prop.format == MPV_FORMAT_DOUBLE {
                let val = prop.data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                     if name == "time-pos" {
                        self?.currentTime = val
                    } else if name == "duration" {
                        self?.duration = val
                    } else if name == "volume" {
                        self?.volume = val
                    } else if name == "speed" {
                        self?.playbackSpeed = val
                    }
                }
            } else if prop.format == MPV_FORMAT_FLAG {
                let val = prop.data.assumingMemoryBound(to: CInt.self).pointee != 0
                DispatchQueue.main.async { [weak self] in
                    if name == "pause" {
                        self?.isPaused = val
                    }
                }
            } else if prop.format == MPV_FORMAT_INT64 {
                let val = prop.data.assumingMemoryBound(to: Int64.self).pointee
                DispatchQueue.main.async { [weak self] in
                    if name == "dwidth" {
                        self?.videoWidth = Int(val)
                    } else if name == "dheight" {
                        self?.videoHeight = Int(val)
                    }
                }
            }
        default:
            break
        }
    }
}

fileprivate func mpvGetOpenGLFunc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
    let symbolName: CFString = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
    guard let addr = CFBundleGetFunctionPointerForName(
        CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString),
        symbolName
    ) else {
        return nil
    }
    return addr
}

fileprivate func mpvUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let layer = bridge(ptr: ctx) as ViewLayer
    layer.update()
}

func bridge<T : AnyObject>(ptr : UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

func mutableRawPointerOf<T : AnyObject>(obj : T) -> UnsafeMutableRawPointer {
    return UnsafeMutableRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}
