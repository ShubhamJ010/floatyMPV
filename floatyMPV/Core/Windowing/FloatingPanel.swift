import AppKit

/// `NSPanel` subclass that opts out of the macOS Accessibility tree.
///
/// Third-party window managers — Swish, Magnet, Rectangle, Moom,
/// Hammerspoon, yabai, AeroSpace — discover and move windows by calling
/// `AXUIElementSetAttributeValue(window, kAXPositionAttribute, …)` and
/// `kAXSizeAttribute` on the `AXWindow` node AppKit auto-generates for
/// every `NSWindow`. The title bar, style mask, and window level are
/// irrelevant to that path; a borderless, non-activating, screen-saver-
/// level window is still a fully-writable accessibility element.
///
/// By overriding `NSAccessibility` to expose no attributes and report
/// itself as ignored, this panel becomes a "no-op" to the Accessibility
/// API. `AXUIElementSetAttributeValue` returns an error because the
/// attributes aren't there to set, and the window managers skip it.
///
/// Trade-off: VoiceOver / Voice Control / Switch Control will not see
/// this window. In-app keyboard, mouse, and drag-and-drop are unaffected.
final class FloatingPanel: NSPanel {

    static let minWindowSize = NSSize(width: 280, height: 180)
    static let maxWindowSize = NSSize(width: 589, height: 360)

    init(contentRect: NSRect, aspectRatio: CGFloat) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.isExcludedFromWindowsMenu = true
        self.hidesOnDeactivate = false
        self.canHide = false
        self.becomesKeyOnlyIfNeeded = false
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.aspectRatio = NSSize(width: aspectRatio, height: 1.0)
        self.minSize = FloatingPanel.minWindowSize
    }

    // MARK: - Accessibility opt-out

    /// Empty attribute list — there is nothing here for AT (or window
    /// managers) to read. The default AppKit implementation returns the
    /// full `AXWindow` schema including `kAXPositionAttribute` and
    /// `kAXSizeAttribute`, which is what Swish / Magnet use to move
    /// the window.
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        return []
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        return nil
    }

    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        return false
    }

    override func accessibilityIsIgnored() -> Bool {
        return true
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        return nil
    }

    /// A borderless `NSPanel` returns `false` from `canBecomeKey` by
    /// default, which would block keyboard shortcuts (Space, arrows, ⇧S,
    /// etc.). We need key-window status so `GestureTrackingView` can
    /// receive `keyDown(with:)`.
    override var canBecomeKey: Bool { true }
}
