import AppKit

/// The throat glyph as a template image, with an optional status dot.
/// Monochrome at rest, amber for an open slow finding, red for stalled.
/// It never animates.
enum MenuBarIcon {
    enum State: Hashable { case rest, slow, stalled }

    nonisolated(unsafe) private static var cache: [State: NSImage] = [:]

    static func image(for state: State) -> NSImage {
        if let hit = cache[state] { return hit }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            // bottle-neck shape from the design: wide mouth, narrow throat
            path.move(to: NSPoint(x: 4.5, y: 15.5))
            path.line(to: NSPoint(x: 13.5, y: 15.5))
            path.line(to: NSPoint(x: 13.5, y: 12))
            path.curve(to: NSPoint(x: 11.2, y: 6.5), controlPoint1: NSPoint(x: 13.5, y: 9.5), controlPoint2: NSPoint(x: 11.2, y: 9))
            path.line(to: NSPoint(x: 11.2, y: 2.5))
            path.line(to: NSPoint(x: 6.8, y: 2.5))
            path.line(to: NSPoint(x: 6.8, y: 6.5))
            path.curve(to: NSPoint(x: 4.5, y: 12), controlPoint1: NSPoint(x: 6.8, y: 9), controlPoint2: NSPoint(x: 4.5, y: 9.5))
            path.close()
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            let foot = NSBezierPath()
            foot.move(to: NSPoint(x: 6.5, y: 1))
            foot.line(to: NSPoint(x: 11.5, y: 1))
            foot.lineWidth = 1.6
            foot.lineCapStyle = .round
            foot.stroke()
            if state != .rest {
                // punch a hole so the dot sits on the bar background
                let hole = NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 7, height: 7))
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                hole.fill()
            }
            return true
        }
        image.isTemplate = state == .rest
        if state == .rest {
            cache[state] = image
            return image
        }
        // dot drawn in colour over the template rendering
        let composed = NSImage(size: size, flipped: false) { rect in
            let tinted = image.copy() as! NSImage
            tinted.isTemplate = false
            let base = NSImage(size: size, flipped: false) { r in
                NSColor.labelColor.set()
                r.fill()
                image.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            base.draw(in: rect)
            let dot = NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12.5, width: 5, height: 5))
            (state == .slow ? NSColor(srgbRed: 0.88, green: 0.54, blue: 0.12, alpha: 1) : NSColor(srgbRed: 0.83, green: 0.22, blue: 0.18, alpha: 1)).setFill()
            dot.fill()
            return true
        }
        composed.isTemplate = false
        cache[state] = composed
        return composed
    }
}
