# Optimization Plan: Fix Snap-Animation Jitter & Reduce GPU Load

> **Status**: Draft  
> **Scope**: Rendering pipeline, snap animation, mpv configuration  
> **Goal**: Eliminate visible jitter during corner-snap glide/settle animations and reduce GPU waste when rendering large videos in a tiny window.

---

## Problem Statement

The previous optimization pass ([CHANGELOG.md](./CHANGELOG.md)) solved drag jitter by suspending OpenGL rendering (`isGestureMoving = true` → `canDraw` returns `false`) during **active two-finger drag**. This works perfectly while the user's fingers are on the trackpad.

However, **after the user lifts their fingers**, the snap animation begins — `SnapEngine.animateSnap` glides the window to a corner then settles it. During this ~1.1 second animation:

1. `isGestureMoving` is already reset to `false` (pickup ended).
2. OpenGL rendering resumes at full rate.
3. `NSAnimationContext.runAnimationGroup` calls `window.animator().setFrame(…, display: true)` — the compositor is now moving the window **and** the renderer is calling `mpv_render_context_render()` simultaneously.
4. The CGL lock contention returns — the same bottleneck that caused drag jitter now causes **snap-animation jitter**.

The problem is amplified with large video files (e.g. 500 MB, 12-minute, 1080p/4K) because:
- mpv decodes at full source resolution even though the window is never larger than 589 × 360.
- Each `mpv_render_context_render()` call uploads a full-resolution frame to the GPU, wasting bandwidth.
- The GPU upload time (2-8ms per frame) blocks the compositor from smoothly interpolating the snap animation.

---

## Root Causes

| # | Cause | File | Impact |
|---|-------|------|--------|
| 1 | `isGestureMoving` is only `true` during active drag, not during the snap animation that follows | [GestureTrackingView.swift](./floatyMPV/Core/Gestures/GestureTrackingView.swift) | Rendering resumes before the window stops moving |
| 2 | `SnapEngine.animateSnap` uses `display: true` which forces redraw on every animation frame | [SnapEngine.swift](./floatyMPV/Core/Snapping/SnapEngine.swift#L55-L60) | Each compositor frame triggers a full OpenGL render |
| 3 | No resolution downscaling — mpv renders at native video resolution (e.g. 1920×1080 or 3840×2160) into a ≤589×360 window | [MPVController.swift](./floatyMPV/Core/Playback/MPVController.swift#L86-L151) | GPU uploads are 3-30× larger than needed |
| 4 | No `vd-lavc-dr` or `video-sync` tuning for the small-window use case | [MPVController.swift](./floatyMPV/Core/Playback/MPVController.swift#L86-L151) | Decode and render pipeline not optimized for PiP |

---

## Milestones

### Milestone 1 — Extend Rendering Bypass to Cover Snap Animations

> **Goal**: The OpenGL renderer stays frozen from the moment the user lifts their fingers until the snap animation completes.  
> **Risk**: Low — same pattern as the existing drag bypass.  
> **Files touched**: `GestureTrackingView.swift`, `SnapEngine.swift`, `ViewLayer.swift` (read-only verification)

#### Changes

**1a. Introduce `isSnapAnimating` flag on `ViewLayer`**

Add a second `@Atomic var isSnapAnimating = false` to `ViewLayer`. Update `canDraw` to freeze rendering when either flag is true:

```swift
// ViewLayer.swift — canDraw
override func canDraw(...) -> Bool {
    if isGestureMoving || isSnapAnimating { return false }
    guard let controller = videoView?.playerController else { return false }
    return forceDraw || controller.shouldRenderUpdateFrame()
}
```

**1b. Wire the flag through the rendering bridge**

`VideoPlayerView` already forwards `isGestureMoving`. Add a parallel `isSnapAnimating: Bool` binding that flows the same way:

```swift
// VideoPlayerView.swift
struct VideoPlayerView: NSViewRepresentable {
    var isSnapAnimating: Bool = false
    // ...
    func updateNSView(_ nsView: VideoView, context: Context) {
        nsView.videoLayer.isGestureMoving = isGestureMoving
        nsView.videoLayer.isSnapAnimating = isSnapAnimating
    }
}
```

**1c. Set the flag around `SnapEngine.animateSnap`**

In `GestureTrackingView.maybeSnapWindowFromRecentSwipe`, the existing `snapAnimationInFlight` flag already tracks the animation lifecycle. Expose this to the SwiftUI layer via a new closure or by bridging through the existing `onPickedUpChanged` mechanism — or preferably, add a dedicated `onSnapAnimatingChanged: ((Bool) -> Void)?` closure:

```swift
// GestureTrackingView.swift
var onSnapAnimatingChanged: ((Bool) -> Void)?

private func maybeSnapWindowFromRecentSwipe(window: NSWindow) {
    // ... existing velocity calculation ...
    snapAnimationInFlight = true
    onSnapAnimatingChanged?(true)      // ← NEW: tell SwiftUI layer
    snapEngine.animateSnap(window: window, velocityX: velocityX, velocityY: velocityY) { [weak self] in
        self?.snapAnimationInFlight = false
        self?.onSnapAnimatingChanged?(false)  // ← NEW: unfreeze rendering
    }
}
```

Then in `ContentView.swift`, add `@State private var isSnapAnimating = false` and pass it down through `GestureSurface` → `GestureTrackingView`.

**1d. Change `SnapEngine` to use `display: false`**

The `window.animator().setFrame(…, display: true)` calls in `SnapEngine` force the compositor to repaint the window contents on every animation frame. Since we are intentionally freezing the GL renderer, change to `display: false`:

```swift
// SnapEngine.swift — animateSnap
window.animator().setFrame(overshootFrame, display: false)
// ...
window.animator().setFrame(targetFrame, display: false)
```

The last video frame is already in the layer's backbuffer — the compositor will slide the frozen image to the corner, which is visually correct.

**1e. Force one redraw after settle completes**

After the settle animation finishes, call `ViewLayer.update(force: true)` so the renderer wakes up and paints a fresh frame at the new position:

```swift
// In the completion handler after snap settle:
self?.onSnapAnimatingChanged?(false)
// The ViewLayer.canDraw gate opens, and the next vsync will paint a fresh frame.
```

#### Verification

- Build and run.
- Drop a large video file (≥500 MB, 1080p+).
- Two-finger swipe to fling the window to a corner.
- The glide and settle should be perfectly smooth — the window slides a frozen video frame.
- Playback resumes seamlessly once the window lands.

---

### Milestone 2 — Downscale Video Rendering to Window Size

> **Goal**: mpv renders video frames at the actual window resolution (~360p), not the source resolution.  
> **Risk**: Medium — requires mpv option validation. May need `vf=scale` filter if `--video-output-levels` alone doesn't work.  
> **Files touched**: `MPVController.swift`, `ViewLayer.swift`

#### Changes

**2a. Set `vd-lavc-o=threads=2` and reduce decode overhead**

Currently `vd-lavc-threads=0` auto-detects, which may spawn too many threads for a PiP window. Limit to 2:

```swift
mpv_set_option_string(mpv, "vd-lavc-threads", "2")
```

**2b. Add a video filter to downscale before rendering**

The most reliable way to reduce GPU upload cost is to downscale in the decode pipeline before the frame reaches OpenGL. Add a `vf` (video filter) that caps the output resolution to the max window size:

```swift
// MPVController.swift — mpvInit()
// Cap decoded output to 640px wide (slightly above max window width of 589
// to allow for scaling headroom). Height auto-calculated from aspect ratio.
mpv_set_option_string(mpv, "vf", "lavfi=[scale=640:-2:flags=fast_bilinear]")
```

This ensures that regardless of the source resolution (1080p, 4K, 8K), the frames hitting the GPU are ≤640px wide — a ~9× pixel reduction for 4K content.

**2c. Set `video-sync=audio` for stable A/V sync**

```swift
mpv_set_option_string(mpv, "video-sync", "audio")
```

This tells mpv to tie frame timing to the audio clock, avoiding jitter from display-sync mismatches in a small overlay window.

**2d. Enable direct rendering if available**

```swift
mpv_set_option_string(mpv, "vd-lavc-dr", "yes")
```

This allows the decoder to write directly into the GPU texture memory, avoiding an extra CPU→GPU copy.

#### Verification

- Load a 4K video and observe GPU usage in Activity Monitor.
- Frame upload time should drop from ~5-8ms to <1ms.
- No visual quality difference at 589×360 window size.
- Audio sync remains tight.

---

### Milestone 3 — Smooth the Snap Animation Timing

> **Goal**: Refine the snap animation curve and duration so the frozen-frame slide feels intentional and premium.  
> **Risk**: Low — purely visual tuning, no state changes.  
> **Files touched**: `SnapEngine.swift`

#### Changes

**3a. Shorten total animation duration**

The current glide (0.62s) + settle (0.52s) = 1.14s total feels long when the video is frozen. Reduce to make the freeze less noticeable:

```swift
struct Config {
    static let glideDuration: TimeInterval = 0.42   // was 0.62
    static let settleDuration: TimeInterval = 0.32  // was 0.52
}
```

Total: 0.74s — fast enough that the frozen frame doesn't feel stuck, slow enough for the elastic overshoot to register.

**3b. Tighten the overshoot distance**

```swift
static let overshootDistance: CGFloat = 5  // was 8
```

A smaller overshoot makes the settle phase shorter and reduces the total time the video is frozen.

**3c. Use a snappier timing curve**

```swift
// Glide: fast start, decelerate strongly
context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.85, 0.25, 1.0)
// Settle: gentle ease-in-out
context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
```

#### Verification

- Side-by-side comparison with the previous animation feel.
- The window should feel "snappy" — quick fling, soft landing.
- No visual jitter at any point during the animation.

---

### Milestone 4 — Polish & Edge Cases

> **Goal**: Handle edge cases and ensure robustness.  
> **Risk**: Low.  
> **Files touched**: `GestureTrackingView.swift`, `ViewLayer.swift`, `ContentView.swift`

#### Changes

**4a. Ensure rendering resumes if snap is interrupted**

If the user touches the trackpad during a snap animation, `isSnapAnimating` must be reset immediately:

```swift
// GestureTrackingView.swift — handleTouchState()
if touchCount == 2 {
    // Cancel any in-flight snap and resume rendering
    if snapAnimationInFlight {
        snapAnimationInFlight = false
        onSnapAnimatingChanged?(false)
    }
    // ... existing pickup logic
}
```

**4b. Guard against stuck freeze state**

Add a safety timeout that unfreezes rendering if the snap completion handler never fires (e.g. window was closed during animation):

```swift
// GestureTrackingView.swift — maybeSnapWindowFromRecentSwipe
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
    guard let self, self.snapAnimationInFlight else { return }
    self.snapAnimationInFlight = false
    self.onSnapAnimatingChanged?(false)
}
```

**4c. Freeze rendering during mouse-drag snap too**

If a future milestone adds mouse-drag-to-snap, the same `isSnapAnimating` gate should apply. The architecture is already extensible because the flag flows through the same `onSnapAnimatingChanged` closure.

**4d. Audit `display:` parameter usage**

Grep for all `setFrame(…, display: true)` calls and verify each is intentional:

| Call site | `display:` value | Correct? |
|-----------|-------------------|----------|
| `handleScrollMove` | `false` | ✅ Already correct |
| `mouseDragged` | `false` | ✅ Already correct |
| `applyPickupWindowScale` | `true` | ⚠️ Consider `false` |
| `SnapEngine.animateSnap` (glide) | `true` → `false` | Fixed in M1 |
| `SnapEngine.animateSnap` (settle) | `true` → `false` | Fixed in M1 |
| `WindowAccessor.configure` | `true` | ✅ One-time setup |
| `magnify` | `false` | ✅ Already correct |

---

## Implementation Order

```
M1 (Rendering Bypass)  ──────────►  M2 (Resolution Downscale)
         │                                    │
         │                                    │
         ▼                                    ▼
M3 (Animation Tuning)  ──────────►  M4 (Polish & Edge Cases)
```

- **M1 is the critical fix** — it eliminates the jitter by extending the existing proven pattern.
- **M2 is the performance win** — it reduces GPU load by up to 9× for 4K content.
- **M3 and M4** are polish that make the fix feel premium.
- Each milestone is independently shippable and verifiable.

---

## Files Changed Summary

| File | Milestones | Change Type |
|------|-----------|-------------|
| [ViewLayer.swift](./floatyMPV/Core/Rendering/ViewLayer.swift) | M1 | Add `isSnapAnimating` flag to `canDraw` |
| [VideoPlayerView.swift](./floatyMPV/Core/Rendering/VideoPlayerView.swift) | M1 | Forward `isSnapAnimating` binding |
| [GestureTrackingView.swift](./floatyMPV/Core/Gestures/GestureTrackingView.swift) | M1, M4 | Add `onSnapAnimatingChanged` closure, safety timeout |
| [GestureSurface.swift](./floatyMPV/Core/Gestures/GestureSurface.swift) | M1 | Forward the new binding to the tracking view |
| [ContentView.swift](./floatyMPV/UI/ContentView.swift) | M1 | Add `@State isSnapAnimating`, pass to `VideoPlayerView` |
| [SnapEngine.swift](./floatyMPV/Core/Snapping/SnapEngine.swift) | M1, M3 | `display: false`, tune durations/curves |
| [MPVController.swift](./floatyMPV/Core/Playback/MPVController.swift) | M2 | Add `vf` downscale filter, `video-sync`, `vd-lavc-dr` |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| `vf=lavfi=[scale=…]` filter may not work with all hwdec codepaths | Fallback: use `--vf=gpu=w=640:h=-2` or `--video-output-levels` | 
| Frozen frame during snap may look odd on first impression | M3 tightens animation to <0.75s — barely noticeable |
| `isSnapAnimating` could get stuck if completion handler is lost | M4 adds a 2s safety timeout |
| Reducing `vd-lavc-threads` to 2 might slow initial decode for very large files | Monitor decode times; revert to `0` if needed |

---

## Success Criteria

1. **Zero visible jitter** during snap animation with a 500 MB / 12-min / 1080p video playing.
2. **GPU frame upload time < 2ms** (down from 5-8ms) measured via Instruments OpenGL profiler.
3. **No audio glitch** when rendering resumes after snap.
4. **No stuck freeze** — rendering always recovers within 2 seconds maximum.
5. **Smooth 60fps** snap animation on both Intel and Apple Silicon Macs.
