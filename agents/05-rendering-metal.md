# Rendering + Metal Agent

## Purpose

Render `libmpv` output through a Metal-backed view for low-latency playback and smooth resizing.

## Owns

- `CAMetalLayer`
- `mpv_render_context`
- Resize synchronization
- Hardware decode-friendly rendering path

## Success criteria

- Rendering stays stable during resize
- CPU usage stays low for normal playback
- Window movement does not disrupt the frame pipeline

## Current milestone

Prototype the render path after basic playback is reachable.

