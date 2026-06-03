//
//  MPVController.swift
//  floatyMPV
//

import Cocoa
import Foundation
import Combine

/// `MPVController` is the bridge between our SwiftUI/AppKit app and `libmpv`
/// (the C playback engine). It owns:
///   - The libmpv handle (`mpv`) and render context (`mpvRenderContext`)
///   - All playback state published to the UI (`@Published` properties)
///   - Commands issued to mpv (load, seek, pause, speed, etc.)
///   - A background event loop that pumps libmpv events back onto the main thread
///
/// Swift developers: think of this as a "wrapper object" around a C library.
/// The `mpv` property is an opaque pointer (`OpaquePointer`) because Swift
/// does not know the concrete type behind it — the real C struct header lives
/// in `mpv/client.h`, imported via the bridging header.
///
/// Rendering context creation happens in `mpvInitRendering(layer:)` and requires
/// an OpenGL context to be current on the calling thread. See `ViewLayer` for where
/// the OpenGL context is created and locked.
class MPVController: NSObject, ObservableObject {
    // MARK: - Published UI State
    //
    // These are what the SwiftUI views observe. Any change here automatically
    // refreshes the UI thanks to Combine's @Published.
    @Published var currentTime: Double = 0.0   // Current playback position in seconds
    @Published var duration: Double = 0.0       // Total video length in seconds
    @Published var isPaused: Bool = true        // Whether playback is currently paused
    @Published var volume: Double = 100.0        // Volume (0-100+)
    @Published var playbackSpeed: Double = 1.0  // Playback rate multiplier
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0
    @Published var hasActiveFile = false         // True after a video is loaded

    /// Computed aspect ratio of the loaded video. Used by `WindowAccessor`
    /// to lock the window shape so the video is not stretched.
    var videoAspectRatio: CGFloat {
        guard videoWidth > 0, videoHeight > 0 else { return 1.0 }
        return CGFloat(videoWidth) / CGFloat(videoHeight)
    }

    // MARK: - C Interop Handles
    //
    // `mpv` is the "handle" — the root object of the libmpv engine.
    // You create it once, and all other operations use it.
    var mpv: OpaquePointer!
    //
    // `mpvRenderContext` wraps the AO/VO (audio/video output) render state.
    // It is created *after* the initial mpv handle and connects libmpv's
    // rendering pipeline to our OpenGL context.
    var mpvRenderContext: OpaquePointer?
    //
    // OpenGL contexts are per-thread on macOS. We capture the context that was
    // current when `mpvInitRendering` was called, and re-assert it (lock/set)
    // around each `mpv_render_context_render()` call. See `lockAndSetOpenGLContext`.
    private var openGLContext: CGLContextObj! = nil

    /// A dedicated background queue for the mpv event loop.
    /// `userInteractive` QoS keeps scroll/grab events responsive.
    /// Do NOT do heavy work on this queue — it feeds from libmpv continuously.
    private lazy var queue = DispatchQueue(label: "com.floatympv.controller", qos: .userInteractive)
    
    /// Flag to signal the event loop to stop during shutdown.
    @Atomic private var isShuttingDown = false

    /// In-memory resume state. `loadfile` in a running mpv session does not
    /// auto-resume from `watch_later`, so we track the last playback position
    /// per file path here and pass it back as the `start` option on the next
    /// `loadfile` of the same path.
    ///
    /// The dictionary is also persisted to `resumeFileURL` on `stop()` and on
    /// shutdown so that `Q` (which closes the window and quits the app) leaves
    /// a trail the next launch can pick up.
    private var lastKnownPositions: [String: Double] = [:]
    private var currentFilePath: String?

    /// `~/Library/Application Support/sj010.floatyMPV/resume.json`. Created on
    /// first access; the directory may not exist on a clean install.
    private var resumeFileURL: URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = support.appendingPathComponent("sj010.floatyMPV", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("resume.json")
    }

    private func loadResumePositions() {
        guard let data = try? Data(contentsOf: resumeFileURL),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
            print("[MPV] no resume positions on disk")
            return
        }
        lastKnownPositions = dict
        print("[MPV] loaded \(dict.count) resume positions from \(resumeFileURL.lastPathComponent)")
    }

    private func saveResumePositions() {
        guard !lastKnownPositions.isEmpty else {
            print("[MPV] saveResumePositions: skipped (empty)")
            return
        }
        do {
            let data = try JSONEncoder().encode(lastKnownPositions)
            try data.write(to: resumeFileURL, options: .atomic)
            print("[MPV] saved \(lastKnownPositions.count) resume positions to \(resumeFileURL.lastPathComponent)")
        } catch {
            print("[MPV] saveResumePositions failed: \(error)")
        }
    }

    override init() {
        super.init()
        mpvInit()
    }

    deinit {
        // Signal the event loop to stop
        isShuttingDown = true
        // Wait for any pending work to complete (up to 1 second timeout)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 1.0)
        
        mpvUninitRendering()
    }

    func mpvInit() {
        // Step 1: create the libmpv handle. This allocates the internal engine.
        mpv = mpv_create()
        guard mpv != nil else {
            print("Failed to create mpv instance")
            return
        }

        // Step 2: options guaranteed to be set *before* mpv_initialize().
        // "vo" = video output driver. "libmpv" means mpv renders itself,
        // leaving presentation to us via mpv_render_context_render().
        mpv_set_option_string(mpv, "vo", "libmpv")
        // hwdec = hardware decoding. On macOS this uses VideoToolbox for H.264/H.265.
        mpv_set_option_string(mpv, "hwdec", "auto")
        // Keep the player active (idle) instead of quitting when there is no file playing.
        mpv_set_option_string(mpv, "idle", "yes")
        // Persist the current playback position when mpv is terminated (e.g. on app quit),
        // so a subsequent app session can resume from watch_later on the next `loadfile`.
        mpv_set_option_string(mpv, "save-position-on-quit", "yes")

        // Step 3: quality / battery tradeoffs tuned for a small floating window.
        // See Architecture.md for rationale.
        //
        // `vd-lavc-threads=2` caps decode parallelism. The default ("0" = auto)
        // can spawn ~8 threads for a 4K stream, which is wasted parallelism for
        // a ≤589×360 window — 2 threads keep latency low without thrashing
        // the GPU upload queue.
        mpv_set_option_string(mpv, "vd-lavc-threads", "2")
        // `vd-lavc-dr=yes` lets the decoder write directly into GPU-backed
        // texture memory, eliminating the intermediate CPU copy before upload.
        mpv_set_option_string(mpv, "vd-lavc-dr", "yes")
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
        // Tie frame presentation to the audio clock. Avoids the display-sync
        // micro-jitter that hurts when the window is small and constantly
        // being repositioned.
        mpv_set_option_string(mpv, "video-sync", "audio")
        // Downscale the frame in the decode pipeline so the GPU never uploads
        // more pixels than the window can show. Cap to 640px wide (slightly
        // above the 589px max window width) — for a 4K source this is a ~9×
        // reduction in upload bandwidth. `-2` preserves aspect ratio rounded
        // to an even height (libavfilter requirement).
        mpv_set_option_string(mpv, "vf", "lavfi=[scale=640:-2:flags=fast_bilinear]")

        // Step 4: register a C callback that libmpv will call when new events
        // (property changes, end-of-file, etc.) are available.
        //
        // The callback receives `ctx`, the pointer we pass as the third argument.
        // We pass `self` by converting it to a raw pointer with `mutableRawPointerOf`
        // and back with `unsafeBitCast`. The lifetime is safe because mpv guarantees
        // it tears the callback down before the controller is destroyed (see deinit).
        mpv_set_wakeup_callback(mpv, { (ctx) in
            guard let ctx = ctx else { return }
            let controller = unsafeBitCast(ctx, to: MPVController.self)
            // Pump events on a background queue — expensive work, main thread stay clear.
            controller.readEvents()
        }, mutableRawPointerOf(obj: self))

        // Step 5: finalize initialization. After this the engine is ready.
        let err = mpv_initialize(mpv)
        if err < 0 {
            print("Failed to initialize mpv: \(String(cString: mpv_error_string(err)))")
        }

        // Step 6: subscribe to mpv "properties" we want to observe.
        // Whenever one changes, mpv emits a `MPV_EVENT_PROPERTY_CHANGE` event.
        // We handle it in `handleEvent(_:)` and mirror the value into @Published.
        //
        // The `0` is the reply_userdata (unused here). Format tells libmpv the C type.
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "dheight", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "idle-active", MPV_FORMAT_FLAG)

        // Step 7: hydrate the in-memory resume dictionary from disk so a re-drop
        // after a previous app session can seek to the last position.
        loadResumePositions()
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

    /// Creates the libmpv **render context** and connects it to our `ViewLayer`'s
    /// OpenGL surface. This must be called *after* the layer has created its
    /// `CGLContextObj` because the context must be current on this thread during
    /// initialization.
    ///
    /// Key concepts:
    ///   - `MPV_RENDER_PARAM_API_TYPE`: tells mpv we intend to use `"opengl"`.
    ///   - `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS`: says "use this function pointer
    ///     lookup helper" (implemented in `MPVPointers.swift` as `mpvGetOpenGLFunc`)
    ///     so libmpv can call `gl*` functions.
    ///   - `MPV_RENDER_PARAM_ADVANCED_CONTROL`: 1 enables `mpv_render_context_render()`
    ///     to be called from the same thread that owns the OpenGL context.
    ///
    /// After creation we install `mpvUpdateCallback`, which libmpv fires whenever
    /// a new decoded frame is ready. The callback receives the `ViewLayer` pointer
    /// and schedules a draw.
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

    /// Frees only the mpv render context — does NOT destroy the mpv handle.
    /// Called from `VideoPlayerView.dismantleNSView` when the view is removed,
    /// so the old `ViewLayer`'s OpenGL context is still alive and valid for cleanup.
    func uninitRendering() {
        guard let context = mpvRenderContext, let glContext = openGLContext else { return }
        
        // Attempt to lock and clear the rendering context. If the context is invalid
        // (e.g., during app termination), we still proceed with cleanup but skip GL calls.
        let lockResult = CGLLockContext(glContext)
        defer {
            if lockResult == kCGLNoError {
                CGLUnlockContext(glContext)
            }
        }
        
        // Only set current context if lock succeeded
        if lockResult == kCGLNoError {
            CGLSetCurrentContext(glContext)
        }
        
        // Unregister the update callback and free the rendering context.
        // This is safe even if the GL context is invalid.
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
        
        mpvRenderContext = nil
        self.openGLContext = nil
    }

    // MARK: - OpenGL Context Safety
    //
    // On macOS, OpenGL is per-thread: a CGLContextObj is "current" on only one thread
    // at a time. Before calling mpv_render_context_render() we lock the context
    // and make it current; after rendering we unlock.
    // See ViewLayer.draw for the matching lock/unlock pair.
    private var contextLocked = false
    
    func lockAndSetOpenGLContext() {
        if let context = openGLContext {
            let result = CGLLockContext(context)
            if result == kCGLNoError {
                CGLSetCurrentContext(context)
                contextLocked = true
            }
        }
    }

    func unlockOpenGLContext() {
        if let context = openGLContext, contextLocked {
            CGLUnlockContext(context)
            contextLocked = false
        }
    }

    func mpvUninitRendering() {
        // Persist before tearing down mpv — after `mpv_terminate_destroy` the
        // handle is invalid and any in-memory state is about to be released.
        saveResumePositions()
        uninitRendering()
        if mpv != nil {
            // Use mpv_terminate_destroy to gracefully shut down the event loop
            // This is safer than mpv_destroy as it properly waits for pending operations
            mpv_terminate_destroy(mpv)
            mpv = nil
        }
    }

    // MARK: - Frame / Render Sync
    //
    // Called by `ViewLayer.canDraw(...)`. Asks libmpv whether a new decoded frame
    // has arrived since the last call. Returns true when `MPV_RENDER_UPDATE_FRAME`
    // is set in the flags bitmask.
    func shouldRenderUpdateFrame() -> Bool {
        guard let context = mpvRenderContext else { return false }
        let flags = mpv_render_context_update(context)
        return (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) > 0
    }

    // Helper to send arbitrary commands to mpv
    func mpvCommand(_ args: [String]) {
        guard let mpv = mpv else { return }
        print("[MPV] cmd> \(args)")
        var cArgs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs {
                if let ptr = ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }
        let err = mpv_command(mpv, &cArgs)
        if err < 0 {
            print("[MPV] cmd< ERR \(err): \(String(cString: mpv_error_string(err))) for \(args)")
        }
    }

    // Load file command
    func loadFile(path: String) {
        print("[MPV] loadFile path=\(path) saved=\(lastKnownPositions[path] ?? -1) hasActive=\(hasActiveFile)")
        savePositionForResume()
        hasActiveFile = true
        currentFilePath = path

        // Same-session resume is handled in `MPV_EVENT_FILE_LOADED` (see
        // `handleEvent`) — the `loadfile` command in this mpv build rejects
        // `start=` in its options string, so we load first and seek after the
        // demuxer reports the file is ready (before the first frame).
        mpvCommand(["loadfile", path, "replace"])
    }

    func togglePause() {
        var flag: CInt = isPaused ? 0 : 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to seconds: Double) {
        mpvCommand(["seek", String(seconds), "absolute"])
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

    func toggleMute() {
        mpvCommand(["cycle", "mute"])
    }

    func toggleSubtitles() {
        mpvCommand(["cycle", "sub-visibility"])
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
        print("[MPV] stop() hasActive=\(hasActiveFile) curPath=\(currentFilePath ?? "nil") lastPos=\(currentFilePath.flatMap { lastKnownPositions[$0] } ?? -1)")
        savePositionForResume()
        // Persist in-memory positions to disk so a `Q` (close + quit) doesn't
        // lose the trail. `time-pos` may not fire between here and the actual
        // shutdown, so capture what we have now.
        saveResumePositions()
        mpvCommand(["stop"])
    }

    /// Writes the current playback position to mpv's watch_later store so the
    /// next `loadfile` of the same path auto-resumes from here. Safe to call
    /// when no file is loaded (no-op via the `hasActiveFile` guard).
    func savePositionForResume() {
        guard hasActiveFile else {
            print("[MPV] savePositionForResume: skipped (no active file)")
            return
        }
        print("[MPV] savePositionForResume: writing watch_later for \(currentFilePath ?? "nil")")
        mpvCommand(["write-watch-later-config"])
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self = self, let mpv = self.mpv else { return }
            while !self.isShuttingDown {
                let event = mpv_wait_event(mpv, 0)!
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE {
                    // No events available, briefly yield to avoid busy-waiting
                    usleep(1000) // 1ms sleep
                    continue
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
        case MPV_EVENT_END_FILE:
            let reason = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
            print("[MPV] EVENT_END_FILE reason=\(reason.rawValue) curPath=\(currentFilePath ?? "nil") lastPos=\(currentFilePath.flatMap { lastKnownPositions[$0] } ?? -1)")
            // If the file reached EOF on its own, the saved position is at the
            // last frame — re-dropping and seeking there would immediately
            // re-end the file. Clear it so a re-drop starts from 0.
            // Stop / quit / error reasons are left alone: those are explicit
            // user intent and the position should remain resume-able.
            if reason.rawValue == MPV_END_FILE_REASON_EOF.rawValue,
               let path = currentFilePath {
                lastKnownPositions.removeValue(forKey: path)
                print("[MPV] EOF reached — cleared resume position for \(path)")
            }
            break
        case MPV_EVENT_FILE_LOADED:
            print("[MPV] EVENT_FILE_LOADED curPath=\(currentFilePath ?? "nil") saved=\(currentFilePath.flatMap { lastKnownPositions[$0] } ?? -1)")
            if let path = currentFilePath,
               let saved = lastKnownPositions[path],
               saved > 0.5 {
                print("[MPV] FILE_LOADED → seeking to \(saved) for \(path)")
                mpvCommand(["seek", String(saved), "absolute"])
            } else {
                print("[MPV] FILE_LOADED (no resume target) for \(currentFilePath ?? "nil")")
            }
            break
        case MPV_EVENT_START_FILE:
            print("[MPV] EVENT_START_FILE curPath=\(currentFilePath ?? "nil")")
            break
        case MPV_EVENT_PROPERTY_CHANGE:
            let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: prop.name)
            if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                let val = data.assumingMemoryBound(to: Double.self).pointee
                DispatchQueue.main.async { [weak self] in
                     if name == "time-pos" {
                        self?.currentTime = val
                        if let path = self?.currentFilePath {
                            self?.lastKnownPositions[path] = val
                        }
                    } else if name == "duration" {
                        self?.duration = val
                    } else if name == "volume" {
                        self?.volume = val
                    } else if name == "speed" {
                        self?.playbackSpeed = val
                    }
                }
            } else if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                let val = data.assumingMemoryBound(to: CInt.self).pointee != 0
                if name == "idle-active" {
                    print("[MPV] prop idle-active=\(val) curPath=\(currentFilePath ?? "nil") (main-queue dispatched)")
                }
                DispatchQueue.main.async { [weak self] in
                    if name == "pause" {
                        self?.isPaused = val
                    } else if name == "idle-active" {
                        // Only mirror the state. Playlist mutation is owned by
                        // `loadfile … replace` and `stop`; doing it here would
                        // race with a same-tick re-load (e.g. W → drop) and
                        // clear the freshly-loaded file → black screen.
                        self?.hasActiveFile = !val
                        if name == "idle-active" {
                            print("[MPV] idle-active applied on main: hasActive=\(self?.hasActiveFile ?? false)")
                        }
                    }
                }
            } else if prop.format == MPV_FORMAT_INT64, let data = prop.data {
                let val = data.assumingMemoryBound(to: Int64.self).pointee
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
