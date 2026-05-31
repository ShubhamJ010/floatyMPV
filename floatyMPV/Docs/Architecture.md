# FloatyMPV Architecture

## Overview

FloatyMPV is a native macOS PiP-style video player using `libmpv` for playback and AppKit/SwiftUI for the UI. The architecture follows domain-oriented separation with isolated core subsystems.

## System Responsibilities

| Layer | Responsibility | Must NOT depend on |
|-------|---------------|-------------------|
| `App/` | Bootstrap, lifecycle, root window | Rendering internals, gesture logic |
| `Core/Playback/` | mpv init, commands, events, state | Windowing, gestures, overlays |
| `Core/Rendering/` | OpenGL context, frame scheduling, mpv_render | Gesture state, UI components, features |
| `Core/Gestures/` | Touch, scroll, pinch, mouse drag detection | mpv internals, rendering impl |
| `Core/Windowing/` | NSWindow config, resize, aspect ratio, z-order | Playback state, rendering |
| `Core/Snapping/` | Corner snap geometry, animation | Everything (operates on NSRect only) |
| `Core/Shortcuts/` | Key→command mapping | Everything (pure decision tree) |
| `UI/` | SwiftUI view composition, reusable controls | Domain logic stays elsewhere |
| `Features/` | Future: overlays, settings, playlists | Core subsystems via narrow interfaces |

## Rendering Flow

```
mpv (libmpv) → MPVController → ViewLayer (CAOpenGLLayer) → VideoView → VideoPlayerView
                  │                    │
                  │  mpv_render_context_render()  ←  OpenGL frame
                  │                    │
                  └─→ mpvUpdateCallback ─→ ViewLayer.update() → setNeedsDisplay
```

1. `MPVController` creates mpv handle and render context
2. `mpv_render_context_set_update_callback` fires when a new frame is ready
3. `ViewLayer.update()` schedules `setNeedsDisplay()` on main thread
4. `canDraw(inCGLContext:)` checks `mpv_render_context_update()` for new frame
5. `draw(inCGLContext:)` calls `mpv_render_context_render()` with OpenGL FBO
6. `glFlush()` submits the command buffer (non-blocking, vsync-aligned)

## Playback Lifecycle

```
App Launch
  ↓
floatyMPVApp (SwiftUI @main)
  ↓
ContentView creates @StateObject MPVController
  ↓
MPVController.mpvInit() in init
  ├── mpv_create()
  ├── mpv_set_option_string() — energy-efficient config
  ├── mpv_set_wakeup_callback() → readEvents()
  ├── mpv_initialize()
  └── mpv_observe_property() — time-pos, duration, pause, etc.
  ↓
VideoPlayerView.makeNSView()
  ├── Creates VideoView with ViewLayer
  └── MPVController.mpvInitRendering(layer:) — creates mpv_render_context
  ↓
File drop → MPVController.loadFile(path:)
  └── mpv_command(["loadfile", path])
  ↓
Event loop: readEvents() → handleEvent() → @Published updates
```

## Gesture Flow

```
SwiftUI ZStack
  ↓
GestureSurface (NSViewRepresentable)
  └── GestureTrackingView (NSView)
        │
        ├── Touches: touchesBegan/Moved/Ended → 2-finger pickup
        ├── Mouse: mouseDown/Dragged/Up → window drag
        ├── Scroll: scrollWheel → display-link smoothed window move
        ├── Pinch: magnify/endGesture → resize window
        ├── Zoom: smartMagnify → toggle fullscreen
        └── Keyboard: keyDown → KeyboardShortcutHandler
              │
              └── SnapEngine.animateSnap() on scroll release
```

## Dependency Boundaries

### Rendering cannot import:
- `GestureTrackingView`, `GestureSurface`
- `ContentView`, `DropZoneOverlay`
- Any `Features/` module

### Playback cannot import:
- `WindowAccessor`, window internals
- `GestureTrackingView`
- `SnapEngine`

### Features cannot:
- Manipulate render internals directly
- Access mpv handles directly

## File Ownership Table

| File | Domain | Dependencies |
|------|--------|--------------|
| `App/floatyMPVApp.swift` | App | `UI/ContentView` |
| `UI/ContentView.swift` | UI | `MPVController`, `WindowAccessor`, `GestureSurface`, `VideoPlayerView`, `DropZoneOverlay`, `VisualEffectView` |
| `Core/Windowing/WindowAccessor.swift` | Windowing | AppKit, SwiftUI |
| `Core/Gestures/GestureSurface.swift` | Gestures | SwiftUI, `MPVController`, `GestureTrackingView` |
| `Core/Gestures/GestureTrackingView.swift` | Gestures | AppKit, QuartzCore, `MPVController`, `KeyboardShortcutHandler`, `SnapEngine` |
| `Core/Shortcuts/KeyboardShortcutHandler.swift` | Shortcuts | AppKit, `MPVController` |
| `Core/Snapping/SnapEngine.swift` | Snapping | AppKit, QuartzCore |
| `Core/Playback/MPVController.swift` | Playback | Cocoa, Combine, mpv C API, `ViewLayer` |
| `Core/Rendering/VideoPlayerView.swift` | Rendering | SwiftUI, `MPVController`, `VideoView` |
| `Core/Rendering/VideoView.swift` | Rendering | Cocoa, `MPVController`, `ViewLayer` |
| `Core/Rendering/ViewLayer.swift` | Rendering | Cocoa, QuartzCore, OpenGL, mpv C API, `VideoView` |
| `UI/DropZoneOverlay.swift` | UI | SwiftUI |
| `UI/VisualEffectView.swift` | UI | SwiftUI, AppKit |
| `Utilities/Concurrency/Atomic.swift` | Utilities | Foundation |
| `Utilities/Extensions/MPVPointers.swift` | Utilities | Cocoa, OpenGL, `ViewLayer` |
