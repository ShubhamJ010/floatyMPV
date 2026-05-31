# FloatyMPV

Native macOS PiP-style video player built with AppKit and `libmpv`.

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
- Rendering: `CAMetalLayer` plus `mpv_render_context`
- Window system: custom `NSWindow`
- Packaging: Swift Package Manager

### Tooling
- **Editor**: Zed / Cursor / VS Code
- **Build**: Xcodebuild / Xcode
- **Dependencies**: Swift Package Manager
- **UI**: SwiftUI + AppKit hybrid
- **Graphics**: Metal
- **Playback**: AVFoundation / libmpv
- **Automation**: Fastlane / Tuist

## Recommended build order

1. Window mechanics
2. Gesture handling
3. Snap engine
4. Playback integration
5. Metal rendering
6. Overlay controls
7. Streaming support
8. Polish and persistence

## Project structure

```text
Sources/
├── App/
├── Window/
├── Playback/
├── Gestures/
├── Snap/
├── Rendering/
├── Overlay/
├── Models/
├── Utilities/
└── Resources/
```

## Agent docs

Implementation agents live in [`agents/`](./agents/). Each file describes one workstream and the scope it owns.

Workflow rules live in [`AGENTS.md`](./AGENTS.md). Read that before touching code.

## Current App Structure

The initial gesture prototype has been split out of `ContentView.swift` into focused types:

- `ContentView.swift` owns the SwiftUI composition and local UI state
- `WindowAccessor.swift` owns `NSWindow` setup and window lifecycle logging
- `GestureSurface.swift` bridges SwiftUI state to the gesture surface
- `GestureTrackingView.swift` owns touch, scroll, pinch, cursor, and keyboard behavior
- `KeyboardShortcutHandler.swift` owns the key-to-command mapping decision tree

That split follows the project rule that `ContentView.swift` should stay small and not mix UI composition with AppKit window or gesture logic.

## Keyboard Shortcuts

All shortcuts are handled by `GestureTrackingView.keyDown(with:)` which delegates to `KeyboardShortcutHandler`. No first-click requirement — the view claims first responder on window attach.

### Playback

| Key | Action |
|---|---|
| `Space` | Toggle play/pause |
| `W` | Stop video and unload file |

### Seek

| Key | Action |
|---|---|
| `←` | Backward 5 seconds |
| `→` | Forward 5 seconds |
| `Z` | Backward 3 seconds |
| `X` | Forward 3 seconds |
| `⌃←` | Backward 30 seconds |
| `⌃→` | Forward 30 seconds |
| `⇧C` | Skip forward 85 seconds (anime opening/ending) |

### Volume

| Key | Action |
|---|---|
| `↑` | Increase 5% |
| `↓` | Decrease 5% |
| `⌃↑` | Increase 20% |
| `⌃↓` | Decrease 20% |

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

### Frame Stepping

| Key | Action |
|---|---|
| `[` | Previous frame |
| `]` | Next frame |

### Window

| Key | Action |
|---|---|
| `Enter` | Toggle fullscreen |
| `F` | Toggle fullscreen |
| `Q` | Close window |

### Capture

| Key | Action |
|---|---|
| `⇧S` | Save screenshot |

### Playlist

| Key | Action |
|---|---|
| `N` | Next file in playlist |

## Status

This repository currently contains the initial design scaffold only. The next step is to create the AppKit window prototype and keep gesture code out of `ContentView.swift` as it grows.
