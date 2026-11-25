import AppKit

@MainActor enum StatusGlyph {
    static func makeImage() -> NSImage {
        // Draw this small template directly without loading the SF Symbols catalog.
        let image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { _ in
            NSColor.black.setStroke()
            let border = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 12, height: 12),
                                      xRadius: 3, yRadius: 3)
            border.lineWidth = 1.25
            border.stroke()

            let arrow = NSBezierPath()
            arrow.lineWidth = 1.25
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 7.5, y: 10.6))
            arrow.line(to: NSPoint(x: 7.5, y: 4.5))
            arrow.move(to: NSPoint(x: 5, y: 7))
            arrow.line(to: NSPoint(x: 7.5, y: 4.5))
            arrow.line(to: NSPoint(x: 10, y: 7))
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
