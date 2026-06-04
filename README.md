# FloatyMPV

Native macOS floating video player inspired by Arc Browser PiP and the system Picture-in-Picture experience — built with AppKit and `libmpv`.

FloatyMPV is a lightweight always-on-top floating video player for macOS designed to stay out of your way while keeping videos instantly accessible anywhere on your desktop.

Drop a video file into the window and it immediately plays inside a compact draggable PiP-style overlay with smooth native animations, magnetic snapping, hardware-accelerated playback, and zero Electron overhead.

Unlike traditional media players, FloatyMPV is focused on a minimal distraction-free floating experience similar to Arc Browser mini player / macOS PiP behavior:
- small floating window
- smooth drag interactions
- native-feeling motion
- always visible
- fast startup
- low memory usage
- optimized for multitasking

Built entirely with native macOS technologies including AppKit, SwiftUI, OpenGL, Core Animation, and `libmpv`.

<img width="800" height="500" alt="CleanShot 2026-06-04 at 13 55 49" src="https://github.com/user-attachments/assets/17679ec3-432c-4d70-8fd9-9162b80c1537" />


---

## Inspiration

This project would not have been realistically possible without the incredible work done by the IINA macOS player and the broader mpv ecosystem.

A huge amount of rendering knowledge, playback behavior, macOS integration patterns, and `libmpv` implementation details were learned by studying IINA and related open-source projects.

Massive respect and thanks to:
- IINA
- mpv

---

## Disclosure

This is primarily a learning and experimentation project.

Heavy use of AI-assisted development workflows and Codex-style agentic coding tools were used during development.

The project is heavily focused on exploring:
- native macOS windowing
- OpenGL rendering
- `libmpv` integration
- gesture systems
- floating utility app architecture
- playback optimization
- smooth native-feeling interactions

Expect architectural experimentation, refactors, and rough edges.

---

## Philosophy

FloatyMPV intentionally prioritizes:
- responsiveness
- low resource usage
- native macOS behavior
- smooth animations
- simplicity
- keyboard-first interactions

over:
- bloated feature sets
- plugin ecosystems
- Electron wrappers
- Chromium-based UI layers

The target experience is simple:

> Open video → drag anywhere → continue working.

---

## What this project is

FloatyMPV is a lightweight floating video player for macOS that aims to feel like a native picture-in-picture window, without Electron.

## Core goals

- Borderless floating window
- Smooth drag and resize interactions
- Magnetic corner snapping
- Always-on-top behavior
- Multi-monitor support
- Hardware-accelerated playback through `libmpv`
- Native AppKit window mechanics

## Architecture & Tooling

### Architecture
- UI: AppKit first
- Playback: `libmpv`
- Rendering: `CAOpenGLLayer` + `mpv_opengl_fbo` + `mpv_render_context_render`
- Window system: custom `NSWindow`
- Packaging: Xcode project

### Tooling
- **Editor**: Zed / Cursor / VS Code
- **Build**: Xcodebuild / Xcode
- **Dependencies**: Xcode project (`.xcodeproj`)
- **UI**: SwiftUI + AppKit hybrid
- **Graphics**: OpenGL
- **Playback**: `libmpv`

### Technology Roles & Responsibilities
- **SwiftUI**: Handles the high-level UI structure, drop zones, visual animations, and coordinates app states (like knowing when the window is "picked up" or not).
- **AppKit**: Manages the low-level macOS window system, mouse/trackpad gestures, and bridges the core operating system events to our code.
- **OpenGL**: Acts as the high-performance GPU "canvas" that allows the video player to draw video frames directly to the screen using hardware acceleration.
- **libmpv (MPV)**: The core playback engine that decodes video files, synchronizes audio, and feeds raw video frame data to OpenGL.
- **CAOpenGLLayer (Core Animation)**: Bridges the gap between raw OpenGL GPU graphics and the macOS window compositor, enabling rounded corners, translucent blur, and native window drop shadows on the video layer.
- **SnapEngine (Magnetic Snapping)**: A pure geometry engine that calculates window physics and animates the window gliding and settling into screen corners.
- **VideoToolbox (Hardware Decoder)**: The native macOS hardware decoding framework used by libmpv to decode H.264/H.265 video streams directly on the Mac's silicon chip to save battery life.

## Recommended build order

1. Window mechanics
2. Gesture handling
3. Snap engine
4. Playback integration
5. Overlay controls
6. Streaming support
7. Polish and persistence

## Architecture

The app follows a domain-oriented architecture with clear ownership boundaries:

```text
floatyMPV/
├── App/                          # Application lifecycle & entry point
│   ├── floatyMPVApp.swift
│   └── MainWindowController.swift  # Owns the FloatingPanel + hosts ContentView
├── Core/                         # Domain subsystems (no UI dependency)
│   ├── Playback/                 # mpv lifecycle, commands, events
│   │   └── MPVController.swift
│   ├── Rendering/                # OpenGL render pipeline (isolated)
│   │   ├── VideoPlayerView.swift  # SwiftUI bridge
│   │   ├── VideoView.swift        # NSView container
│   │   └── ViewLayer.swift        # CAOpenGLLayer + mpv_render_context_render
│   ├── Gestures/                 # Touch, scroll, pinch, mouse drag
│   │   ├── GestureSurface.swift      # SwiftUI→AppKit bridge
│   │   └── GestureTrackingView.swift # NSResponder gesture handling
│   ├── Windowing/                # NSWindow setup, resize, aspect ratio
│   │   └── FloatingPanel.swift   # NSPanel subclass (opt-out of Accessibility)
│   ├── Snapping/                 # Magnetic corner snap (geometry only)
│   │   └── SnapEngine.swift
│   └── Shortcuts/                # Keyboard shortcut mapping (pure logic)
│       └── KeyboardShortcutHandler.swift
├── Features/                     # Future: overlays, settings, playlists, PiP
├── UI/                           # Reusable SwiftUI presentation components
│   ├── ContentView.swift         # View composition & drop handling
│   ├── DropZoneOverlay.swift
│   └── VisualEffectView.swift    # NSVisualEffectView bridge
├── Utilities/                    # Shared helpers (grouped by domain)
│   ├── Concurrency/              # Thread-safe wrappers
│   │   └── Atomic.swift
│   └── Extensions/               # C interop helpers
│       └── MPVPointers.swift
├── Resources/                    # Assets.xcassets
├── Support/                      # Bridging header, build configuration
│   └── floatyMPV-Bridging-Header.h
├── Tests/                        # Future test targets
└── Docs/                         # Architecture documentation
```

## Architectural Rules

### Dependency direction
```
UI → Core
Features → Core
Core subsystems are independent of each other
```

### Rendering isolation
- Rendering (`Core/Rendering/`) must NOT import gestures, overlays, or feature modules.

### Playback independence
- Playback must NOT know about windowing internals or gesture state.

### Snapping is geometry-only
- SnapEngine operates on NSRect only — no playback or windowing dependency.

Workflow rules live in [`AGENTS.md`](./AGENTS.md). Read that before touching code.

## Current Architecture

The app uses a hybrid SwiftUI/AppKit architecture. The window is owned by AppKit (so we can subclass `NSPanel` and opt out of the Accessibility tree); the rest of the UI is SwiftUI hosted inside that panel via `NSHostingController`:

- `App/floatyMPVApp.swift` — `@main` entry point, sets `.accessory` activation policy, instantiates `MainWindowController`
- `App/MainWindowController.swift` — `NSWindowController` that owns the `FloatingPanel`, hosts `ContentView` via `NSHostingController`, applies aspect-ratio lock and resize clamp
- `UI/ContentView.swift` — SwiftUI composition and local UI state, drop handling, posts `.videoAspectRatioChanged` for the controller to react to
- `Core/Windowing/FloatingPanel.swift` — `NSPanel` subclass with `NSAccessibility` opt-out (see "Window management" below)
- `Core/Gestures/GestureSurface.swift` — SwiftUI bridge to the gesture surface
- `Core/Gestures/GestureTrackingView.swift` — touch, scroll, pinch, cursor, keyboard
- `Core/Shortcuts/KeyboardShortcutHandler.swift` — key-to-command mapping
- `Core/Rendering/VideoPlayerView.swift` → `VideoView.swift` → `ViewLayer.swift` — OpenGL rendering
- `Core/Playback/MPVController.swift` — `libmpv` lifecycle, rendering context, command API
- `Core/Snapping/SnapEngine.swift` — magnetic corner snap (extracted from gesture layer)
- `Utilities/Concurrency/Atomic.swift` — thread-safe property wrapper
- `Utilities/Extensions/MPVPointers.swift` — C interop helpers

## Window management

The player is a borderless, accessory-app floating panel. The visible behavior is "Mac native PiP" — no Dock icon, no menu bar, always above other windows — and the window is **invisible to third-party window managers** (Swish, Magnet, Rectangle, Moom, Hammerspoon, yabai, AeroSpace).

### Why a custom `NSPanel`

SwiftUI's `WindowGroup` creates an internal `NSWindow` subclass we can't override. That class auto-generates an `AXWindow` accessibility node containing `kAXPositionAttribute` and `kAXSizeAttribute`, which is exactly what window managers read and write to move windows. To opt out of the accessibility tree, the window has to be a class we own.

`FloatingPanel` is an `NSPanel` subclass with five `NSAccessibility` overrides:

```swift
override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] { return [] }
override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? { return nil }
override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool { return false }
override func accessibilityIsIgnored() -> Bool { return true }
override func accessibilityHitTest(_ point: NSPoint) -> Any? { return nil }
```

`AXUIElementSetAttributeValue(window, kAXPositionAttribute, …)` now returns an error because the attribute isn't there to set, and the window managers skip the panel.

### Activation & lifecycle

`AppDelegate.applicationWillFinishLaunching` calls `NSApp.setActivationPolicy(.accessory)` so the process has no Dock entry and no menu bar. `applicationDidFinishLaunching` instantiates `MainWindowController` and then `NSApp.activate(ignoringOtherApps: true)` — this single activation makes the `FloatingPanel` the key window so it can receive drag-and-drop, clicks, and the keyboard shortcut chain (Space, arrows, `Q`, `⇧S`, …) routed through `GestureTrackingView.keyDown(with:)`.

### Trade-off

`NSAccessibility` opt-out means VoiceOver / Voice Control / Switch Control will not see this window. In-app input, mouse, drag-and-drop, and the `GestureTrackingView` responder chain are all unaffected.

## MPV Configuration

`MPVController.mpvInit()` tunes the player for a small, energy-efficient floating window. These are the actual options set on startup:

| Option | Value | Purpose |
|---|---|---|
| `vo` | `libmpv` | Render into the application's own surface |
| `hwdec` | `auto` | Enable VideoToolbox hardware decoding when available |
| `vd-lavc-threads` | `0` | Auto-detect decode thread count |
| `opengl-pbo` | `yes` | Faster GPU uploads via pixel buffer objects |
| `opengl-glfinish` | `no` | Non-blocking; `glFlush` is used instead |
| `framedrop` | `vo` | Drop render frames to keep audio in sync |
| `video-reversal-buffer` | `disabled` | Disable reversal buffer (not needed for linear playback) |
| `vd-lavc-fast` | `yes` | Fast decode hacks for responsiveness |
| `vd-lavc-skiploopfilter` | `nonref` | Skip non-reference frames to save energy |
| `scale` / `dscale` / `cscale` | `bilinear` | Cheap scaling filters (no GPU waste on a small window) |
| `scale-antiring` | `0.0` | No antiringing cost |
| `correct-downscaling` | `no` | Skip correction passes |
| `linear-downscaling` | `no` | Skip linear correction |
| `linear-upscaling` | `no` | Skip linear correction |
| `video-latency-hacks` | `yes` | Lower decode latency for snappier playback |
| `save-position-on-quit` | `yes` | Persist playback position to `watch_later` on quit / stop / drop-replace, so a re-drop resumes where it left off |

**Observed properties**: `time-pos`, `duration`, `pause`, `volume`, `speed`, `dwidth`, `dheight`.

These choices trade maximum quality for responsiveness and battery life, which is the right trade-off for a PiP-style floating player.

## Loading Videos

Drag and drop a video file onto the window. Supported extensions: `mp4`, `mkv`, `avi`, `mov`, `m4v`, `flv`.

Re-dropping a video that was previously stopped (or whose app session was quit) resumes playback from the last saved position. Position state is delegated to mpv's built-in `watch_later` store — no app-side persistence is involved. The first drop of a file always starts from `0`.

## Keyboard Shortcuts

All shortcuts are handled by `GestureTrackingView.keyDown(with:)` which delegates to `KeyboardShortcutHandler`. No first-click requirement — the view claims first responder on window attach.

### Playback

| Key | Action |
|---|---|
| `Space` | Toggle play/pause |
| `W` | Stop, clear queue, reset to pre-playback state |
| `Q` | Stop, clear queue, reset state, then close window |

### Seek

| Key | Action |
|---|---|
| `J` | Backward 30 seconds |
| `K` | Forward 30 seconds |
| `Z` | Backward 3 seconds |
| `X` | Forward 3 seconds |
| `⇧C` | Skip forward 85 seconds (anime opening/ending) |

### Volume

| Key | Action |
|---|---|
| `L` | Increase 5% |
| `H` | Decrease 5% |
| `M` | Toggle mute |

### Subtitles

| Key | Action |
|---|---|
| `C` | Toggle captions |

### Playback Speed

| Key | Action |
|---|---|
| `S` | Slow down by 0.1x |
| `D` | Speed up by 0.1x |
| `A` | Reset to 1.0x |
| `1` / `Numpad1` | Set 1.0x |
| `2` / `Numpad2` | Set 2.0x |
| `3` / `Numpad3` | Set 3.0x |
| `4` / `Numpad4` | Set 4.0x |

### Capture

| Key | Action |
|---|---|
| `⇧S` | Save screenshot |

### Playlist

| Key | Action |
|---|---|
| `N` | Next file in playlist |

## Status

A working prototype exists with a borderless floating AppKit window, magnetic corner snapping, `libmpv` OpenGL playback, keyboard shortcuts, and drag-and-drop file loading.

The current focus is stabilizing gesture interactions and refining window behavior before adding overlay controls or streaming support.
