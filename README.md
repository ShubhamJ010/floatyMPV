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

## Architecture direction

- UI: AppKit first
- Playback: `libmpv`
- Rendering: `CAMetalLayer` plus `mpv_render_context`
- Window system: custom `NSWindow`
- Packaging: Swift Package Manager

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
- `GestureTrackingView.swift` owns touch, scroll, pinch, and cursor behavior

That split follows the project rule that `ContentView.swift` should stay small and not mix UI composition with AppKit window or gesture logic.

## Status

This repository currently contains the initial design scaffold only. The next step is to create the AppKit window prototype and keep gesture code out of `ContentView.swift` as it grows.
