//
//  SnapEngine.swift
//  floatyMPV
//

import AppKit
import QuartzCore

/// Drives magnetic corner snapping for floating window.
///
/// Operates purely on window geometry — no knowledge of playback,
/// gestures, or rendering.
struct SnapEngine {
    struct Config {
        static let cornerInset: CGFloat = 16
        static let velocityWindow: CFTimeInterval = 0.10
        static let overshootDistance: CGFloat = 8
        static let glideDuration: TimeInterval = 0.62
        static let settleDuration: TimeInterval = 0.52
    }

    private enum Corner {
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

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Config.glideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.90, 0.30, 1.0)
            window.animator().setFrame(overshootFrame, display: true)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Config.settleDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.88, 0.28, 1.0)
                window.animator().setFrame(targetFrame, display: true)
            } completionHandler: {
                completion()
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
