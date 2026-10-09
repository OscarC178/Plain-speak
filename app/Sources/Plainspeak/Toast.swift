import AppKit

/// A short message near the top of the screen that fades by itself, for things like
/// "Select your own draft text first". Never steals focus.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.91, alpha: 1)
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 520
        let size = label.fittingSize
        let box = NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 24)
        let p = NSPanel(contentRect: box, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let back = NSView(frame: box)
        back.wantsLayer = true
        back.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.13, alpha: 0.96).cgColor
        back.layer?.cornerRadius = 12
        label.frame = NSRect(x: 20, y: 12, width: size.width, height: size.height)
        back.addSubview(label)
        p.contentView = back
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - box.width / 2, y: screen.maxY - box.height - 40))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
    }
}
