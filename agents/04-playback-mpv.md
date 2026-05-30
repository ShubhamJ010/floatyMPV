# Playback + mpv Agent

## Purpose

Embed `libmpv` and expose a stable playback layer for local files and later stream support.

## Owns

- `mpv_create`
- `mpv_initialize`
- `mpv_command`
- Player state model
- Local file loading

## Success criteria

- Video can be loaded and played in-app
- Playback survives window resizing
- Integration stays isolated from window logic

## Current milestone

Prepare the bridge layer, but keep it behind the window prototype.

