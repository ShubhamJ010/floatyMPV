import AppKit

/// Pure mapping from keyboard events to playback commands and window actions.
///
/// Keeps the decision tree out of the view layer. Returns `true` when the
/// event is consumed so the view can skip `super.keyDown`.
///
/// Keycodes used here are macOS hardware keycodes (not characters). For example:
///   - `49` = Space bar
///   - `123` = Left arrow
///   - `126` = Up arrow
///
/// The `where mods == .control` pattern checks for the Control (⌃) modifier
        /// held alongside the key.
        /// The `where mods == .shift` pattern checks for Shift (⇧) held with the key.
struct KeyboardShortcutHandler {

    static func handle(_ event: NSEvent, controller: MPVController, window: NSWindow) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode

        switch key {

        // ── Playback ──────────────────────────────────────────────

        case 49 where mods.isEmpty:          // Space
            controller.togglePause()
            return true

        // ── Seek ──────────────────────────────────────────────────

        case 123 where mods.isEmpty:         // ←   -5s
            controller.seekRelative(-5); return true
        case 124 where mods.isEmpty:         // →   +5s
            controller.seekRelative(5); return true
        case 6 where mods.isEmpty:           // Z   -3s
            controller.seekRelative(-3); return true
        case 7 where mods.isEmpty:           // X   +3s
            controller.seekRelative(3); return true
        case 123 where mods == .control:     // ⌃← -30s
            controller.seekRelative(-30); return true
        case 124 where mods == .control:     // ⌃→ +30s
            controller.seekRelative(30); return true
        case 8 where mods == .shift:         // ⇧C  +85s (skip opening)
            controller.seekRelative(85); return true

        // ── Volume ────────────────────────────────────────────────

        case 126 where mods.isEmpty:         // ↑   +5%
            controller.addVolume(5); return true
        case 125 where mods.isEmpty:         // ↓   -5%
            controller.addVolume(-5); return true
        case 126 where mods == .control:     // ⌃↑ +20%
            controller.addVolume(20); return true
        case 125 where mods == .control:     // ⌃↓ -20%
            controller.addVolume(-20); return true

        // ── Playback Speed ────────────────────────────────────────

        case 1 where mods.isEmpty:           // S   -0.1
            controller.setSpeed(controller.playbackSpeed - 0.1); return true
        case 2 where mods.isEmpty:           // D   +0.1
            controller.setSpeed(controller.playbackSpeed + 0.1); return true
        case 0 where mods.isEmpty:           // A   reset to 1.0
            controller.setSpeed(1.0); return true
        case 18 where mods.isEmpty:          // 1
            controller.setSpeed(1); return true
        case 19 where mods.isEmpty:          // 2
            controller.setSpeed(2); return true
        case 20 where mods.isEmpty:          // 3
            controller.setSpeed(3); return true
        case 21 where mods.isEmpty:          // 4
            controller.setSpeed(4); return true
        case 83 where mods.isEmpty:          // Numpad1
            controller.setSpeed(1); return true
        case 84 where mods.isEmpty:          // Numpad2
            controller.setSpeed(2); return true
        case 85 where mods.isEmpty:          // Numpad3
            controller.setSpeed(3); return true
        case 86 where mods.isEmpty:          // Numpad4
            controller.setSpeed(4); return true

        // ── Frame Stepping ────────────────────────────────────────

        case 30 where mods.isEmpty:          // ]
            controller.frameStep(); return true
        case 33 where mods.isEmpty:          // [
            controller.frameBackStep(); return true

        // ── Fullscreen ────────────────────────────────────────────

        case 36 where mods.isEmpty:          // Enter
            window.toggleFullScreen(nil); return true
        case 3 where mods.isEmpty:           // F
            window.toggleFullScreen(nil); return true

        // ── Close / Stop ──────────────────────────────────────────

        case 13 where mods.isEmpty:          // W   stop + clear queue + reset
            controller.stop(); return true
        case 12 where mods.isEmpty:          // Q   stop + clear queue + reset + close
            controller.stop()
            window.close(); return true

        // ── Screenshot ────────────────────────────────────────────

        case 1 where mods == .shift:         // ⇧S
            controller.screenshot(); return true

        // ── Playlist ──────────────────────────────────────────────

        case 45 where mods.isEmpty:          // N
            controller.playlistNext(); return true

        default:
            return false
        }
    }
}
