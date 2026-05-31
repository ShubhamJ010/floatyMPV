# FloatyMPV — Concepts Primer for New Swift Developers

This file explains the non-Swift concepts you will encounter in the codebase.
Read it before touching `ViewLayer.swift`, `MPVController.swift`, or anything under `Core/Rendering/`.

---

## 1. What is libmpv?

`libmpv` is a C library that plays video files. It handles:
- **Decoding**: turning an `.mp4` / `.mkv` file into raw video frames
- **Demuxing**: separating audio, video, and subtitle tracks inside a container
- **Audio output**: pushing decoded audio to macOS CoreAudio
- **Rendering**: drawing decoded video frames onto a surface you provide

You do **not** create windows or views with libmpv. It is a playback engine. You give it a target surface and it draws frames there.

In this project we talk to libmpv through its **C API** (header files listed in
`Support/floatyMPV-Bridging-Header.h`). Because it is a C library, all calls look
different from Swift — they use `OpaquePointer`, `UnsafePointer`, and constants
like `MPV_RENDER_PARAM_API_TYPE`.

---

## 2. What is mpv's OpenGL Rendering Path?

Video frames are textures on the GPU. libmpv exposes a single rendering entry
point named `mpv_render_context_render()`. To use it:

1. Create an `mpv_handle` (`mpv_create()`) — the core playback engine.
2. Tell mpv which renderer we want: `vo = libmpv` instead of `vo = sdl`.
3. Create a **render context** (`mpv_render_context_create()`) that knows how
   to upload decoded frames into the **OpenGL framebuffer** we provide.
4. Every time mpv decodes a new frame, it calls an **update callback**
   (`mpvUpdateCallback` in `Utilities/Extensions/MPVPointers.swift`) and we
   schedule a redraw.
5. Inside the draw call (`ViewLayer.draw(inCGLContext:)`) we pass an OpenGL
   FBO handle to `mpv_render_context_render()`, and it paints the frame.

The alternative (without OpenGL) would be `vo = sdl`, which creates its own
window and handles its own rendering. We do *not* use that because we need a
custom AppKit window.

---

## 3. What is OpenGL doing here (briefly)?

OpenGL is a cross-platform GPU API. In this app it exists solely to give libmpv
a surface to draw onto. You do not need to understand shaders.

Key types you will see:
- **CGLContextObj** — an OpenGL rendering context on macOS. Think of it as the
  "current GPU state." Only one context is current per thread at a time.
- **CGLPixelFormatObj** — describes the format of pixels on screen
  (bits per channel, double buffering, OpenGL profile version).
- **FBO (Framebuffer Object)** — an OpenGL object that represents where pixels
  are written. `ViewLayer` queries the existing FBO id via `glGetIntegerv(...)`
  and passes that id to libmpv so frames arrive in the right place.

---

## 4. What is CAOpenGLLayer?

`CAOpenGLLayer` is a `CALayer` subclass that bridges **Core Animation** with
**OpenGL**. It allows Core Animation's compositor to treat an OpenGL surface as
a normal layer inside the layer tree.

This matters because:
- The window is borderless, transparent, and composited by macOS.
- `VideoView.layer` is a `CAOpenGLLayer`, so the video appears inside the
  normal view hierarchy with alpha, rounded corners, drop shadows, etc.
- `canDraw(inCGLContext:pixelFormat:forLayerTime:displayTime:)` lets Core
  Animation ask "do you have something new to draw?" at vsync.
- `draw(inCGLContext:pixelFormat:forLayerTime:displayTime:)` is where we hand
  control to libmpv, which draws the new frame into the already-open GL context.

Without `CAOpenGLLayer` we would be fighting the macOS compositor and
transparent window would not work.

---

## 5. The Rendering Call Chain (end-to-end)

```
User drops file on window
  ↓
ContentView.handleDrop() → MPVController.loadFile(path:)
  ↓
mpv_command(["loadfile", "/path/to/video.mp4"])  (C call)
  ↓
libmpv opens file, starts decoding
  ↓
New frame ready → mpv calls mpvUpdateCallback (C callback)
  ↓
MPVPointers.mpvUpdateCallback bridges back to ViewLayer.update()
  ↓
ViewLayer.update() calls setNeedsDisplay()
  ↓
Core Animation calls canDraw(...) → we ask mpv_render_context_update()
  ↓
If a new frame exists, Core Animation calls draw(...)
  ↓
draw(...) passes the current OpenGL FBO to mpv_render_context_render(...)
  ↓
libmpv uploads the decoded frame as a texture and draws it into our FBO
  ↓
glFlush() submits work to GPU (non-blocking)
  ↓
macOS compositor blends the CAOpenGLLayer into the window, including
rounded corners, shadow, and transparency
```

---

## 6. Common C-Interop Patterns in This Codebase

You will see these repeatedly. Treat them as a vocabulary list:

| Pattern | Meaning |
|---------|---------|
| `OpaquePointer!` | A C pointer where Swift does not know the concrete type. `mpv`, `mpvRenderContext`. |
| `UnsafeMutablePointer<T>` | Pointer to a single `T` value that C code may read/write. Used to pass flags via `mpv_render_param`. |
| `UnsafeMutableRawPointer` | Untyped pointer. Used when the C callback signature is `void *`. |
| `strdup` + `free` | C strings (`char *`) must be allocated and freed manually. `mpvCommand` allocates, defers `free`. |
| `mpv_set_option_string` / `mpv_set_property` | Configure mpv before (`option`) or after (`property`) initialization. |
| `@Published` + `Combine` | mpv events arrive on a background queue; we dispatch back to main and update `@Published` properties so the SwiftUI views refresh automatically. |
| `DispatchQueue.main.async` | All UI mutations must happen on the main thread. |

---

## 7. Threading Model (summary)

- **Main thread**: SwiftUI rendering, window frame mutations, `@Published` updates.
- **Background `mpvGLQueue`**: libmpv event loop (`readEvents` / `mpv_wait_event`). Never block this queue.
- **`CVDisplayLink` thread**: vsync-rate callbacks that apply smoothed scroll deltas to `window.frame`.
- **OpenGL**: only one context is current at a time. `lockAndSetOpenGLContext()` /
  `unlockOpenGLContext()` make that explicit before calling `mpv_render_context_render`.

---

## 8. What Each Major Subsystem Owns

| Subsystem | Owns | Must NOT touch |
|-----------|------|----------------|
| `MPVController` | mpv lifetime, commands, published state | OpenGL FBO layout, window frame math |
| `ViewLayer` | CAOpenGLLayer lifecycle, draw gating, passing OpenGL params to mpv | Keyboard shortcuts, drag math, snap animation |
| `GestureTrackingView` | All touch/mouse/scroll/pinch input, cursor hide/show | Video decoding, FBO ids |
| `WindowAccessor` | `NSWindow` style, level, aspect-ratio constraint, size clamping | Playback commands |
| `SnapEngine` | Corner geometry and animation duration | Playback, gestures, window configuration |
| `KeyboardShortcutHandler` | Key-code → `MPVController` method mapping | UI state, window frame manipulation (except fullscreen) |

---

## Glossary (keep nearby)

- **libmpv**: the C playback engine (decode + render).
- **vo (video output)**: libmpv config that selects the renderer. We use `libmpv`.
- **hwdec**: hardware decoding — on macOS this means VideoToolbox.
- **PBO (Pixel Buffer Object)**: GPU-side staging buffer for faster uploads.
- **FBO (Framebuffer Object)**: the OpenGL object pixels are drawn into.
- **CAOpenGLLayer**: Core Animation layer that opens a door for OpenGL to draw inside the macOS compositor.
- **vsync**: the moment the display refreshes. `CVDisplayLink` fires at this rate.
- **DispatchQueue / Combine**: standard Swift concurrency and reactive state tools.
