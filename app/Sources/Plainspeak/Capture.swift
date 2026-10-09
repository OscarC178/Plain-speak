import AppKit
import ScreenCaptureKit

/// What a capture is for.
enum Mode: String { case read, correct, draft }

/// Grabs what the reader is looking at and hands it to the local service.
/// Highlighted text is the focus when there is some: Claude gets that text, plus a band of the
/// window above and below it with the selection outlined. Otherwise it gets the whole window,
/// with a ring where the reader pointed.
final class Capture {
    struct Payload: Encodable {
        let app: String
        let title: String
        let mode: String
        let text: String?
        let context: Bool
        var image_base64: String?
        var pointer: Pointer?
        var outlined: Bool?
    }
    struct Pointer: Encodable { let x: Double; let y: Double; var marked: Bool? }
    /// What to send, and where on screen the panel should open (Cocoa coordinates).
    struct Grab { let payload: Payload; let anchor: NSPoint }
    /// A mark drawn on the screenshot, in screen points with the origin at the top left.
    private enum Marker { case ring(CGPoint), box(CGRect) }

    /// Debug builds only: overrides the pointer as fractions of the window, and saves each grab.
    var pointerOverride: Pointer?
    let saveDirectory = ProcessInfo.processInfo.environment["PLAINSPEAK_SAVE_CAPTURES"].map { URL(fileURLWithPath: $0) }

    /// Collects the capture. Returns nil after telling the reader what is missing.
    /// `usePointer` is false for menu actions, because the pointer is then on the menu, not the message.
    func grab(mode: Mode, context: Bool, usePointer: Bool) async -> Grab? {
        guard AXIsProcessTrusted() else {
            await say("Plainspeak needs Accessibility. Turn it on in System Settings, then try again.")
            await MainActor.run { Settings.open(.accessibility) }
            return nil
        }
        let canRecord = CGPreflightScreenCaptureAccess()
        if mode != .draft, !canRecord {
            CGRequestScreenCaptureAccess()
            await say("Plainspeak needs Screen Recording. Turn it on in System Settings, then quit and reopen Plainspeak.")
            await MainActor.run { Settings.open(.screenRecording) }
            return nil
        }
        // Capture before showing anything, so the panel never becomes the input.
        let (mouse, mainHeight) = await MainActor.run { (NSEvent.mouseLocation, NSScreen.screens.first?.frame.height ?? 0) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            await say("Click the window with the message first.")
            return nil
        }
        let selection = selection(pid: app.processIdentifier)
        if mode == .draft, selection.text == nil {
            await say("Select your own draft text first. Some apps do not share their selection with macOS.")
            return nil
        }
        let window = focusedWindow(pid: app.processIdentifier)
        var payload = Payload(app: app.localizedName ?? "Unknown", title: window?.title ?? "", mode: mode.rawValue, text: selection.text, context: context)
        // Cocoa measures from the bottom left of the main screen; Accessibility and the window list from the top left.
        let toCocoa = { (p: CGPoint) in NSPoint(x: p.x, y: mainHeight - p.y) }
        guard let window else {
            if mode == .draft { return Grab(payload: payload, anchor: mouse) } // the selected text is enough for a draft
            await say("No window to read. Click the message window first.")
            return nil
        }
        let frame = window.frame
        let pointer: CGPoint? = pointerOverride.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
            ?? (usePointer ? CGPoint(x: mouse.x, y: mainHeight - mouse.y) : nil)
        let pointerInWindow = pointer.flatMap { frame.contains($0) ? $0 : nil }
        // Without a pointer (menu actions), open the panel inside the top right of the window.
        var anchor = usePointer ? mouse : toCocoa(CGPoint(x: frame.maxX - 40, y: frame.minY + 60))

        var crop: CGRect?      // part of the window to send, in its own points; nil sends all of it
        var marker: Marker?
        var located = false    // whether we know where the highlighted text is
        if selection.text != nil {
            if let bounds = selection.bounds?.intersection(frame), !bounds.isNull, bounds.width > 0, bounds.height > 0 {
                crop = band(around: bounds, in: frame)
                marker = .box(bounds)
                located = true
                anchor = toCocoa(CGPoint(x: bounds.maxX, y: bounds.minY))
            } else if let p = pointerInWindow {
                // The app does not say where the selection is; the pointer is usually where it ended.
                crop = band(around: CGRect(origin: p, size: .zero), in: frame)
                marker = .ring(p)
                located = true
            }
            // A draft without a known position, or without Screen Recording, goes as text alone.
            if mode == .draft, !located || !canRecord { return Grab(payload: payload, anchor: anchor) }
        } else if let p = pointerInWindow {
            marker = .ring(p) // no selection: the whole window, with a ring where the reader points
        }

        let region = crop.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) } ?? frame
        guard let png = await screenshot(windowID: window.id, crop: crop, marker: marker, region: region) else {
            if mode == .draft { return Grab(payload: payload, anchor: anchor) }
            await say("Could not capture the window. Check Screen Recording for Plainspeak.")
            return nil
        }
        payload.image_base64 = png.base64EncodedString()
        switch marker {
        case .ring(let p):
            let round = { (v: Double) in (v * 100).rounded() / 100 }
            payload.pointer = Pointer(x: round((p.x - region.minX) / region.width), y: round((p.y - region.minY) / region.height), marked: true)
        case .box: payload.outlined = true
        case nil: break
        }
        save(png: png, payload: payload)
        return Grab(payload: payload, anchor: anchor)
    }

    /// Debug launches only: selects the first `needle` in the focused text of the front app, as if
    /// the reader had highlighted it. Works in native text views such as TextEdit.
    /// Returns nil on success, or which step failed.
    func debugSelect(_ needle: String) -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "no front app" }
        var focused: CFTypeRef?, value: CFTypeRef?, role: CFTypeRef?
        let found = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused)
        guard found == .success, let focused else { return "\(app.localizedName ?? "?"): no focused element (\(found.rawValue))" }
        let element = focused as! AXUIElement
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let where_ = "\(app.localizedName ?? "?") \(role as? String ?? "?")"
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { return "\(where_): no text value" }
        guard let match = text.range(of: needle) else { return "\(where_): text not found in \(text.count) characters" }
        var range = CFRange(location: text.utf16.distance(from: text.utf16.startIndex, to: match.lowerBound), length: needle.utf16.count)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return "could not make a range" }
        let set = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        return set == .success ? nil : "\(where_): setting the selection failed (\(set.rawValue))"
    }

    /// Debug launches only: resizes the front window, so tests can make room for a cropped band.
    func debugResize(width: CGFloat, height: CGFloat) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return false }
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: - Window

    /// The focused window of the front app: Accessibility says which window has focus,
    /// and the on-screen window list (front to back) gives its ID for capture.
    private func focusedWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect, title: String)? {
        var focusedFrame: CGRect?
        var title = ""
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            let window = value as! AXUIElement
            focusedFrame = frame(of: window)
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success {
                title = titleValue as? String ?? ""
            }
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [(CGWindowID, CGRect)] = list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 40, rect.height > 40 else { return nil }
            return (id, rect)
        }
        let match = focusedFrame.flatMap { f in windows.first { abs($0.1.minX - f.minX) < 4 && abs($0.1.minY - f.minY) < 4 && abs($0.1.width - f.width) < 4 && abs($0.1.height - f.height) < 4 } }
        guard let chosen = match ?? windows.first else { return nil }
        return (chosen.0, chosen.1, title)
    }

    /// Window frame in global coordinates with the origin at the top left (as the window list uses).
    private func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    // MARK: - Selection

    /// The highlighted text, and where it is on screen when the app says so.
    private func selection(pid: pid_t) -> (text: String?, bounds: CGRect?) {
        var focused: CFTypeRef?, selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return (nil, nil) }
        let element = focused as! AXUIElement
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
        return (String(text.prefix(40000)), selectionBounds(element))
    }

    /// Native text views describe a selection as a character range; web pages (Safari, Chrome and
    /// Electron apps such as Slack) as a text-marker range. Either can be turned into a screen rectangle.
    private func selectionBounds(_ element: AXUIElement) -> CGRect? {
        for (rangeAttribute, boundsAttribute) in [(kAXSelectedTextRangeAttribute as String, kAXBoundsForRangeParameterizedAttribute as String),
                                                  ("AXSelectedTextMarkerRange", "AXBoundsForTextMarkerRange")] {
            var range: CFTypeRef?, bounds: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, rangeAttribute as CFString, &range) == .success, let range,
                  AXUIElementCopyParameterizedAttributeValue(element, boundsAttribute as CFString, range, &bounds) == .success, let bounds,
                  CFGetTypeID(bounds) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 { return rect }
        }
        return nil
    }

    /// A full-width band of the window from well above the focus to a little below it, so Claude sees
    /// the conversation around it. In the window's own points; nil when that is most of the window anyway.
    private func band(around focus: CGRect, in window: CGRect) -> CGRect? {
        let above: CGFloat = 380, below: CGFloat = 220, least: CGFloat = 360
        var top = max(window.minY, focus.minY - above), bottom = min(window.maxY, focus.maxY + below)
        if bottom - top < least { bottom = min(window.maxY, top + least); top = max(window.minY, bottom - least) }
        if bottom - top > window.height * 0.85 { return nil }
        return CGRect(x: 0, y: top - window.minY, width: window.width, height: bottom - top)
    }

    // MARK: - Screenshot

    /// The window, or a band of it, at its full pixel size (Retina), without shadow or cursor,
    /// capped at 2560 px on the long edge and below the service's size limit.
    private func screenshot(windowID: CGWindowID, crop: CGRect?, marker: Marker?, region: CGRect) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = crop?.size ?? filter.contentRect.size
        var scale = min(CGFloat(filter.pointPixelScale), 2560 / max(size.width, size.height))
        for _ in 0..<6 {
            let config = SCStreamConfiguration()
            if let crop { config.sourceRect = crop }
            config.width = max(1, Int(size.width * scale))
            config.height = max(1, Int(size.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            guard var image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
            if let marker { image = mark(image, marker, region: region) }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            if png.count * 4 / 3 <= 7_500_000 { return png } // base64 must fit the service's limit
            scale *= 0.8
        }
        return nil
    }

    /// Pink with a white edge, readable on light and dark apps. A ring where the reader pointed, or
    /// an outline around the highlighted text, each with a clear centre so it hides as little as possible.
    private func mark(_ image: CGImage, _ marker: Marker, region: CGRect) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Screen points (origin top left) to bitmap pixels (origin bottom left).
        let sx = w / region.width, sy = h / region.height
        let px = { (p: CGPoint) in CGPoint(x: (p.x - region.minX) * sx, y: h - (p.y - region.minY) * sy) }
        let path: CGPath, line: CGFloat
        switch marker {
        case .ring(let p):
            let radius = max(14, max(w, h) * 0.012), c = px(p)
            line = radius / 4
            path = CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        case .box(let r):
            let corner = px(CGPoint(x: r.minX, y: r.maxY)), pad = 4 * sx // bottom-left corner of the selection in the bitmap
            line = max(3, 1.5 * sx)
            path = CGPath(roundedRect: CGRect(x: corner.x - pad, y: corner.y - pad, width: r.width * sx + pad * 2, height: r.height * sy + pad * 2),
                          cornerWidth: 6 * sx, cornerHeight: 6 * sx, transform: nil)
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)); ctx.setLineWidth(line * 2); ctx.addPath(path); ctx.strokePath()
        ctx.setStrokeColor(CGColor(red: 1, green: 0.18, blue: 0.58, alpha: 1)); ctx.setLineWidth(line); ctx.addPath(path); ctx.strokePath()
        return ctx.makeImage() ?? image
    }

    // MARK: - Helpers

    private func save(png: Data, payload: Payload) {
        guard let dir = saveDirectory else { return }
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(stamp).png"))
        var meta = payload
        meta.image_base64 = nil
        if let json = try? JSONEncoder().encode(meta) { try? json.write(to: dir.appendingPathComponent("\(stamp).json")) }
    }

    @MainActor private func say(_ text: String) { Toast.show(text) }
}

/// System Settings panes Plainspeak sends you to.
enum Settings {
    case accessibility, screenRecording
    static func open(_ pane: Settings) { // call on the main thread
        let anchor = pane == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
