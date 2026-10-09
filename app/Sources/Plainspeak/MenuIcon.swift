import AppKit

/// The menu bar icon: the "p." from assets/icon.svg as a template image, so macOS
/// colours it for light and dark menu bars. Geometry is taken from the SVG.
enum MenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // The glyph spans x 214...810 and y 224...800 in the 1024 px SVG.
            let k: CGFloat = 16 / 576, ox: CGFloat = 0.7, oy: CGFloat = 1
            func x(_ v: CGFloat) -> CGFloat { ox + (v - 214) * k }
            func y(_ v: CGFloat) -> CGFloat { oy + (v - 224) * k }
            NSColor.black.set()
            NSBezierPath(roundedRect: NSRect(x: x(214), y: y(224), width: 92 * k, height: 576 * k), xRadius: 46 * k, yRadius: 46 * k).fill()
            let bowl = NSBezierPath(ovalIn: NSRect(x: x(430 - 170), y: y(440 - 170), width: 340 * k, height: 340 * k))
            bowl.lineWidth = 92 * k
            bowl.stroke()
            NSBezierPath(ovalIn: NSRect(x: x(748 - 62), y: y(594 - 62), width: 124 * k, height: 124 * k)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
