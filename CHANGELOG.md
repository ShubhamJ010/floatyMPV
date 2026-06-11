# Changelog

## v0.2.0 — 2026-06-12 — YouTube Streaming & Loading UI

**What changed**

- **yt-dlp streaming support.** `MPVController` now configures mpv's built-in `ytdl_hook.lua` with `ytdl=yes` and a quality ladder (`bestvideo[height<=720]+bestaudio/best[height<=480]/best`). Calls `findYtdlBinary()` at init to locate the binary (bundled → `/opt/homebrew` → `/usr/local`). A new `loadMedia(_ pathOrURL:)` method dispatches HTTP/HTTPS URLs to mpv's `loadfile` command and local files to the existing `loadFile` path.
- **⌘V paste URL.** `KeyboardShortcutHandler` reads `NSPasteboard.general` on ⌘V, detects HTTP/HTTPS strings, and routes them through `loadMedia`. No first-click requirement — the window responder is active.
- **Drop URL support.** `ContentView.onDrop` now accepts `UTType.url` in addition to `UTType.fileURL`. Drops from Safari's address bar (or any browser) load directly into the player.
- **Loading / buffering UI.** Added `isLoading`, `isViewReady`, `isBuffering` published properties. `ContentView` shows a `ProgressView` spinner during URL resolution (`isLoading`) and during seeks (`isBuffering`), with a `VisualEffectView(.hudWindow)` backdrop.
- **Flash‑prevention for seek buffering.** The spinner stays visible until *both* mpv's `seeking` property returns `false` *and* `ViewLayer.draw()` produces a new frame. Prevents a visual flash between seek-complete and first-decoded frame.
- **`viewDidRender()` callback.** `ViewLayer.draw()` calls `controller.viewDidRender()` after every successful render, which transitions `isViewReady` (first frame) and clears `isBuffering` (post-seek frame arrived).
- **`seeking` property observation.** `MPVController` subscribes to mpv's `seeking` flag. On rising edge: sets `isBuffering = true`. On falling edge: sets `bufferCleared = true` (frame gate). Also observed: `idle-active` for clean state mirroring during streaming transitions.
- **`vd-lavc-threads=2`.** Reduced from `0` (auto, ~8 threads for 4K) to cap decode parallelism, keeping latency low for the small 589×360 window.
- **Copy yt-dlp build phase.** Xcode project now includes a `PBXShellScriptBuildPhase` that copies `Resources/yt-dlp` into the app bundle at build time. `ENABLE_USER_SCRIPT_SANDBOXING = NO` required for the script phase.
- **`Scripts/update-ytdlp.sh`.** Downloads the latest macOS universal binary from `yt-dlp/yt-dlp` releases into `Resources/yt-dlp`.
- **`DropZoneOverlay` text.** Updated from "Drop to Play Video" / "Drop Video Here" to "Drop to Play" / "Drop Video or Paste URL".
- **Resume position fix for streams.** `MPV_EVENT_END_FILE` no longer resets `isLoading` on non-error reasons, so a `loadfile … replace` (new URL while playing) doesn't overwrite the loading state set by `loadMedia`.

**Why it broke before**

mpv has no built-in UI for loading states. Without `isLoading` / `isViewReady` / `isBuffering`, streaming URL resolution was invisible — the window stayed dark until the stream resolved. Seek transitions were also invisible, making the player feel unresponsive. The buffering overlay needed explicit frame-gating to avoid a flash between "seek done" and "frame rendered."

**Files touched**

- `floatyMPV/Core/Playback/MPVController.swift`
- `floatyMPV/UI/ContentView.swift`
- `floatyMPV/Core/Rendering/ViewLayer.swift`
- `floatyMPV/Core/Shortcuts/KeyboardShortcutHandler.swift`
- `floatyMPV/UI/DropZoneOverlay.swift`
- `floatyMPV.xcodeproj/project.pbxproj`
- `README.md`
- `Scripts/update-ytdlp.sh`
- `.gitignore`

---

# Session Changelog: Gesture Smoothness Optimization 🛠️📖

This changelog documents the optimizations made to resolve window-drag jitter during active video playback. It serves as an educational reference for Swift, AppKit, and OpenGL developers working on the `floatyMPV` codebase.

---

## 🆕 2026-06-04 — Resume Playback & Removed Seek-Mute

**What changed**

- **Same-session resume.** `MPVController` now keeps an in-memory `lastKnownPositions: [String: Double]` keyed by file path, updated on every `time-pos` event. On `MPV_EVENT_FILE_LOADED` we look up the path and `seek` to the saved position before the first frame is rendered, so a re-drop of the same file picks up where you left off.
- **Cross-session resume.** `lastKnownPositions` is persisted to `~/Library/Application Support/sj010.floatyMPV/resume.json`. Loaded in `mpvInit`; saved in `stop()` and `mpvUninitRendering()`. The `Q` shortcut (stop + close) now survives an app quit — re-launching and re-dropping the same file resumes.
- **EOF clears the saved slot.** When `MPV_EVENT_END_FILE` fires with `MPV_END_FILE_REASON_EOF`, we `removeValue(forKey:)` for the current path so a re-drop of a fully-watched file starts from 0 instead of seeking to the last frame and re-ending immediately.
- **Dropped the seek-mute hack.** `performSeekMuted`, `seekMuteRestore`, and the `isMuted` `@Published` property are gone. `seek` / `seekRelative` are back to plain one-liners.
- **Removed the `playlist-clear` race.** The `idle-active` handler used to dispatch `playlist-clear` to the main queue, which could wipe a freshly-loaded file on a `W → drop` same-tick. `loadfile … replace` already owns playlist replacement; the handler now only mirrors `hasActiveFile`.
- **Diagnostics.** `mpvCommand` logs the command and any `MPV_ERROR_*` return; `loadFile`, `stop`, `savePositionForResume`, `idle-active`, and the file lifecycle events (`START_FILE` / `FILE_LOADED` / `END_FILE`) print state for debugging.

**Why it broke before**

mpv's `loadfile` does **not** auto-resume from `watch_later` within a running session — only on fresh mpv startup. So `write-watch-later-config` + a later `loadfile` in the same process never connected. The `start=` option in the `loadfile` options string is rejected outright by this mpv build (`MPV_ERROR_INVALID_PARAMETER`). The fix had to be: load the file, then `seek` after `MPV_EVENT_FILE_LOADED` fires.

**Files touched**

- `floatyMPV/Core/Playback/MPVController.swift`

---

## 🎯 Main Goal
**Deliver perfectly smooth, zero-latency window-drag interactions (60fps+) using trackpad swipe gestures, even during active high-definition hardware video playback.**

---

## 🔍 The Bottlenecks Identified

1. **OpenGL Context Lock Contention:**
   During active playback, `ViewLayer.swift` calls `mpv_render_context_render(...)` which locks the OpenGL rendering context (`CGLLockContext`) on the drawing thread for 2-8ms per frame. Since window movement requires window compositor invalidation, executing `setFrame` while the context was locked caused frame updates to stall, resulting in severe jitter.

2. **Thread Dispatch Latency:**
   The gesture system tracked scrolling deltas through a separate `CVDisplayLink` thread loop, which then pushed window mutations back to the main thread via `DispatchQueue.main.async`. This asynchronous hop added unpredictable scheduling delays.

---

## 🛠️ The Fixes

### 1. The Rendering Bypass Gate
* **File:** `Core/Rendering/ViewLayer.swift`
* **Fix:** Introduced an `@Atomic var isGestureMoving` property to suspend OpenGL rendering during active dragging.
* **Why:** By avoiding rendering updates for the fraction of a second the window is being swiped, the OpenGL context lock is never held, allowing the window compositor to move the window with zero competition. Rendering resumes instantly the moment the user lifts their fingers.

```swift
@Atomic var isGestureMoving = false

override func canDraw(...) -> Bool {
    if isGestureMoving {
        return false // Freeze drawing during gestures to release the CGL lock!
    }
    return forceDraw || controller.shouldRenderUpdateFrame()
}
```

### 2. Direct Main-Thread Event Updates
* **File:** `Core/Gestures/GestureTrackingView.swift`
* **Fix:** Completely removed the complex `CVDisplayLink` timer loop, its sync locks, and associated threads. Trackpad swiping events now update the window frame synchronously.
* **Why:** AppKit trackpad events are already highly optimized and rate-limited. Moving the window immediately inside the event queue provides instant, hardware-level physical response.

```swift
private func handleScrollMove(with event: NSEvent, source: String) -> Bool {
    // ...
    let rawDelta = CGPoint(x: dx, y: -dy)
    recordScrollSample(dx: rawDelta.x, dy: rawDelta.y)

    // Move window immediately on the main event thread
    var nextFrame = window.frame
    nextFrame.origin.x += rawDelta.x
    nextFrame.origin.y += rawDelta.y
    window.setFrame(nextFrame, display: false, animate: false)

    return true
}
```

### 3. SwiftUI to AppKit State Bridge
* **Files:** `UI/ContentView.swift` & `Core/Rendering/VideoPlayerView.swift`
* **Fix:** Passed SwiftUI's `@State private var isPickedUp` property down to the `VideoPlayerView` bridge wrapper, updating the AppKit `ViewLayer` dynamically.
* **Why:** Ensures the rendering engine knows when the user is swiping the window, matching SwiftUI's reactive UI state to our low-level graphics code cleanly.

```swift
// SwiftUI Composition
if playerController.hasActiveFile {
    VideoPlayerView(playerController: playerController, isGestureMoving: isPickedUp)
}
```

---

## 💡 Lessons for Developers
* **KISS (Keep It Simple, Stupid):** We solved the latency issue by deleting over 50 lines of complex threaded code (`CVDisplayLink`), proving that simpler implementations are often faster and cleaner.
* **Prioritize User Physics:** Human eyes immediately detect input-tracking lag. Temporarily prioritizing window positioning over rendering frames makes the app feel extremely premium.
* **Clean Boundaries:** Passing a clean `isGestureMoving: Bool` across modules ensures that components stay decoupled and testable.
