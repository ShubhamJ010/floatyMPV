# IINA and mpv: Architecture Analysis

This document outlines how IINA uses `mpv` (and by extension FFmpeg's `libavcodec`) under the hood, serving as a blueprint for implementing playback in the Swift app `floatyMPV`.

## 1. Core Architecture
IINA is a macOS video player written in Swift, which acts as a frontend UI to the powerful `mpv` command-line player. It integrates `mpv` natively using its C API (`libmpv`), wrapping it inside a Swift class typically named `MPVController`.

Behind the scenes, `mpv` relies heavily on FFmpeg libraries (like `libavcodec`, `libavformat`, `libavutil`, and `libswscale`) for parsing and decoding media streams. By using `libmpv`, IINA gets access to all the decoding power of FFmpeg while controlling the presentation, UI, and macOS-specific integrations natively.

## 2. Initialization and Setup
In IINA, the `mpv` instance is initialized through standard C API calls:

```swift
// 1. Create the instance
mpv = mpv_create()

// 2. Set options before initialization
// e.g. Hardware decoding whitelist
mpv_set_option_string(mpv, "hwdec-codecs", "h264,hevc,prores,vp9")

// 3. Initialize the core
mpv_initialize(mpv)
```

**Hardware Decoding & `libavcodec`:**
During initialization, IINA adjusts the `hwdec-codecs` option based on hardware capabilities. This option is directly passed down by `mpv` to FFmpeg (`libavcodec`). If a codec is supported by macOS's VideoToolbox framework, `libavcodec` decodes it via hardware; otherwise, it falls back to software decoding. IINA includes logic (e.g., `adjustCodecWhiteList()`) to explicitly remove codecs unsupported by the Mac (like AV1 on older Macs) to prevent FFmpeg from logging alarming "Failed setup" errors before falling back to software.

## 3. The Event Loop
Because `mpv` is asynchronous and needs to communicate state changes (playback progress, properties changing, errors), it provides an event queue. IINA uses a dedicated background `DispatchQueue` to poll this event queue so it doesn't block the main thread.

```swift
// A callback is registered to wake up the queue when new events are available
mpv_set_wakeup_callback(self.mpv, { (ctx) in
    // Signal the background queue to read events
})

// The readEvents loop runs on a background GCD queue
private func readEvents() {
    queue.async {
        while ((self.mpv) != nil) {
            let event = mpv_wait_event(self.mpv, 0)!
            if event.pointee.event_id == MPV_EVENT_NONE { break }
            
            self.handleEvent(event) // e.g. MPV_EVENT_SHUTDOWN, MPV_EVENT_PROPERTY_CHANGE
        }
    }
}
```
**Important Note:** The mpv event queue has a limited size. If events aren't read fast enough, the queue overflows and events drop, leading to malfunctions. This is why IINA does very minimal processing on the background queue and dispatches UI updates back to the `main` thread.

## 4. Property Observation
Instead of constantly polling for the current time or state, IINA registers observers.

```swift
// Observing properties
mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
```

When an observed property changes, `mpv_wait_event` yields a `MPV_EVENT_PROPERTY_CHANGE` event. IINA then unpacks the event data and updates its UI accordingly.

## 5. Rendering Pipeline
IINA uses `mpv`'s render API (`mpv_render_context`) to draw video frames natively in a macOS view.

```swift
// Initialize OpenGL/Metal rendering context
var apiType = MPV_RENDER_API_TYPE_OPENGL
// Parameters are set up with mpv_render_param

mpv_render_context_create(&mpvRenderContext, mpv, &params)

// Set a callback to update the view when a new frame is ready
mpv_render_context_set_update_callback(mpvRenderContext, mpvUpdateCallback, ...)
```
When `mpv` decodes a frame, it calls the `update_callback`. IINA then issues a draw call to OpenGL (or Metal), executing `mpv_render_context_render` to present the frame into the native UI layer.

## 6. Commands and Control
To play media, pause, or seek, IINA issues commands to `mpv` using the command API:

```swift
// Example: Load a file
let cargs: [UnsafePointer<Int8>?] = ["loadfile", "path/to/video.mp4", nil]
mpv_command(self.mpv, &cargs)

// Example: Async command
mpv_command_async(self.mpv, replyUserdata, &cargs)
```

## Summary for floatyMPV
To implement playback in `floatyMPV`, you will need to:
1. Link against `libmpv` (which statically or dynamically links `libavcodec` and FFmpeg).
2. Create an `MPVController` Swift class that manages the `mpv_handle`.
3. Call `mpv_create()` and `mpv_initialize()`.
4. Setup a `DispatchQueue` to loop `mpv_wait_event` and route events to the Main Thread.
5. Create a render context (`mpv_render_context_create`) connected to an `NSOpenGLView` or `MTKView`.
6. Issue commands like `loadfile` via `mpv_command`.
