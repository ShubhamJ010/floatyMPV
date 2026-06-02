//
//  SnapEngine.swift
//  floatyMPV
//

import AppKit
import QuartzCore

/// Drives the magnetic corner-snap animation for the floating window.
///
/// This type is explicitly geometry-only: it knows nothing about playback,
/// gestures, or how the window is rendered. It takes an `NSWindow`, a velocity
/// vector, and produces an animated frame change — then finishes.
///
/// The animation has two phases:
///   1. **Glide** — the window quickly overshoots the target corner (elastic feel).
///   2. **Settle** — the window eases into the final resting position.
///
/// Which corner? Choosen by dot-product alignment between:
///   - the "swipe direction" (the direction the finger was moving), and
///   - the vector from the window center to each corner center.
///
/// For a new Swift developer: physics / animation imports are *not* required.
/// This is pure `NSAnimationContext` + geometry math.
struct SnapEngine {
    struct Config {
        static let cornerInset: CGFloat = 16
        static let velocityWindow: CFTimeInterval = 0.10
        static let overshootDistance: CGFloat = 8
        static let glideDuration: TimeInterval = 0.58
        static let settleDuration: TimeInterval = 0.52
    }

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    func animateSnap(window: NSWindow, velocityX: CGFloat, velocityY: CGFloat, completion: @escaping () -> Void) {
        let visibleFrame = resolveVisibleFrame(for: window.frame)
        let corner = resolveCorner(
            velocityX: velocityX,
            velocityY: velocityY,
            currentFrame: window.frame,
            visibleFrame: visibleFrame
        )
        let targetFrame = targetFrame(for: window.frame, in: visibleFrame, corner: corner)
        let overshootFrame = overshootFrame(from: window.frame, target: targetFrame)

        // `display: false` is intentional: the GL renderer is suspended for the
        // duration of this animation (see ViewLayer.isSnapAnimating), and the
        // compositor slides the last-painted frame to the new origin. Asking
        // for `display: true` here would force a repaint per animation tick
        // and reintroduce the CGL lock contention we just eliminated.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Config.glideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.90, 0.30, 1.0)
            window.animator().setFrame(overshootFrame, display: false)
        } completionHandler: {
            // Unfreeze rendering immediately when the glide phase ends and the window
            // arrives at the corner. The subsequent settle phase is tiny (5pt) and
            // slow, so we can render normally during it without causing jitter.
            completion()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Config.settleDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.88, 0.28, 1.0)
                window.animator().setFrame(targetFrame, display: false)
            }
        }
    }

    private func resolveCorner(velocityX: CGFloat, velocityY: CGFloat, currentFrame: NSRect, visibleFrame: NSRect) -> Corner {
        let speed = max(hypot(velocityX, velocityY), 0.001)
        let swipeVector = NSPoint(x: velocityX / speed, y: velocityY / speed)
        let windowCenter = NSPoint(x: currentFrame.midX, y: currentFrame.midY)

        let cornerCenters: [(Corner, NSPoint)] = [
            (.topLeft, NSPoint(
                x: visibleFrame.minX + Config.cornerInset + (currentFrame.width / 2.0),
                y: visibleFrame.maxY - Config.cornerInset - (currentFrame.height / 2.0)
            )),
            (.topRight, NSPoint(
                x: visibleFrame.maxX - Config.cornerInset - (currentFrame.width / 2.0),
                y: visibleFrame.maxY - Config.cornerInset - (currentFrame.height / 2.0)
            )),
            (.bottomLeft, NSPoint(
                x: visibleFrame.minX + Config.cornerInset + (currentFrame.width / 2.0),
                y: visibleFrame.minY + Config.cornerInset + (currentFrame.height / 2.0)
            )),
            (.bottomRight, NSPoint(
                x: visibleFrame.maxX - Config.cornerInset - (currentFrame.width / 2.0),
                y: visibleFrame.minY + Config.cornerInset + (currentFrame.height / 2.0)
            ))
        ]

        var bestCorner: Corner = .bottomRight
        var bestScore: CGFloat = -.infinity

        for (corner, center) in cornerCenters {
            let vx = center.x - windowCenter.x
            let vy = center.y - windowCenter.y
            let length = max(hypot(vx, vy), 0.001)
            let directionToCorner = NSPoint(x: vx / length, y: vy / length)
            let dot = (directionToCorner.x * swipeVector.x) + (directionToCorner.y * swipeVector.y)

            if dot > bestScore {
                bestScore = dot
                bestCorner = corner
            }
        }

        return bestCorner
    }

    private func resolveVisibleFrame(for windowFrame: NSRect) -> NSRect {
        let windowCenter = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screens = NSScreen.screens

        if let direct = screens.first(where: { $0.visibleFrame.contains(windowCenter) }) {
            return direct.visibleFrame
        }

        return screens.min(by: {
            squaredDistance(from: windowCenter, to: $0.visibleFrame) <
            squaredDistance(from: windowCenter, to: $1.visibleFrame)
        })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? windowFrame
    }

    private func targetFrame(for currentFrame: NSRect, in visibleFrame: NSRect, corner: Corner) -> NSRect {
        let width = currentFrame.width
        let height = currentFrame.height
        let inset = Config.cornerInset

        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .topLeft:
            x = visibleFrame.minX + inset
            y = visibleFrame.maxY - height - inset
        case .topRight:
            x = visibleFrame.maxX - width - inset
            y = visibleFrame.maxY - height - inset
        case .bottomLeft:
            x = visibleFrame.minX + inset
            y = visibleFrame.minY + inset
        case .bottomRight:
            x = visibleFrame.maxX - width - inset
            y = visibleFrame.minY + inset
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func overshootFrame(from currentFrame: NSRect, target: NSRect) -> NSRect {
        var frame = target
        let dx = target.midX - currentFrame.midX
        let dy = target.midY - currentFrame.midY
        let distance = max(hypot(dx, dy), 0.001)
        frame.origin.x += (dx / distance) * Config.overshootDistance
        frame.origin.y += (dy / distance) * Config.overshootDistance
        return frame
    }


    /// Determines which screen corner a window frame is anchored to, if any.
    /// Returns `nil` if the window is not close enough to any corner.
    /// The tolerance threshold is 20 points from the ideal corner position.
    static func anchoredCorner(for windowFrame: NSRect, in visibleFrame: NSRect) -> Corner? {
        let inset = Config.cornerInset
        let tolerance: CGFloat = 20.0

        // The fixed corner point for each snapped position
        let topLeftAnchor     = NSPoint(x: visibleFrame.minX + inset, y: visibleFrame.maxY - inset)
        let topRightAnchor    = NSPoint(x: visibleFrame.maxX - inset, y: visibleFrame.maxY - inset)
        let bottomLeftAnchor  = NSPoint(x: visibleFrame.minX + inset, y: visibleFrame.minY + inset)
        let bottomRightAnchor = NSPoint(x: visibleFrame.maxX - inset, y: visibleFrame.minY + inset)

        // The corresponding corner of the current window frame
        let windowTopLeft     = NSPoint(x: windowFrame.minX, y: windowFrame.maxY)
        let windowTopRight    = NSPoint(x: windowFrame.maxX, y: windowFrame.maxY)
        let windowBottomLeft  = NSPoint(x: windowFrame.minX, y: windowFrame.minY)
        let windowBottomRight = NSPoint(x: windowFrame.maxX, y: windowFrame.minY)

        if hypot(windowTopLeft.x - topLeftAnchor.x, windowTopLeft.y - topLeftAnchor.y) < tolerance {
            return .topLeft
        }
        if hypot(windowTopRight.x - topRightAnchor.x, windowTopRight.y - topRightAnchor.y) < tolerance {
            return .topRight
        }
        if hypot(windowBottomLeft.x - bottomLeftAnchor.x, windowBottomLeft.y - bottomLeftAnchor.y) < tolerance {
            return .bottomLeft
        }
        if hypot(windowBottomRight.x - bottomRightAnchor.x, windowBottomRight.y - bottomRightAnchor.y) < tolerance {
            return .bottomRight
        }

        return nil
    }

    private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return (dx * dx) + (dy * dy)
    }
}

/// Velocity sample recorded during scroll-gesture window dragging.
struct ScrollSample {
    let time: CFTimeInterval
    let dx: CGFloat
    let dy: CGFloat
}
