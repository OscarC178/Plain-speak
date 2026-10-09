import AppKit
import ScreenCaptureKit

/// What a capture is for.
enum Mode: String { case read, correct, draft }

/// Grabs what the reader is looking at and hands it to the local service:
/// the focused window (sharp, Retina), any selected text, and where the pointer was.
final class Capture {
    struct Payload: Encodable {
        let app: String
        let title: String
        let mode: String
        let text: String?
        let context: Bool
        var image_base64: String?
        var pointer: Pointer?
    }
    struct Pointer: Encodable { let x: Double; let y: Double; var marked: Bool? }
    struct Grab { let payload: Payload; let pointer: NSPoint }

    /// Debug builds only: overrides the pointer as fractions of the window, and saves each grab.
    var pointerOverride: Pointer?
    let saveDirectory = ProcessInfo.processInfo.environment["PLAINSPEAK_SAVE_CAPTURES"].map { URL(fileURLWithPath: $0) }

    /// Collects the capture. Returns nil after telling the reader what is missing.
    func grab(mode: Mode, context: Bool) async -> Grab? {
        guard AXIsProcessTrusted() else {
            await say("Plainspeak needs Accessibility. Turn it on in System Settings, then try again.")
            await MainActor.run { Settings.open(.accessibility) }
            return nil
        }
        if mode != .draft, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            await say("Plainspeak needs Screen Recording. Turn it on in System Settings, then quit and reopen Plainspeak.")
            await MainActor.run { Settings.open(.screenRecording) }
            return nil
        }
        // Capture before showing anything, so the panel never becomes the input.
        let (pointer, mainHeight) = await MainActor.run { (NSEvent.mouseLocation, NSScreen.screens.first?.frame.height ?? 0) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            await say("Click the window with the message first.")
            return nil
        }
        let text = selectedText(pid: app.processIdentifier)
        if mode == .draft, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            await say("Select your own draft text first. Some apps do not share their selection with macOS.")
            return nil
        }
        let window = focusedWindow(pid: app.processIdentifier)
        var payload = Payload(app: app.localizedName ?? "Unknown", title: window?.title ?? "", mode: mode.rawValue, text: text, context: context)

        // Drafts use the selection only; everything else sends the window.
        if mode != .draft {
            guard let window else { await say("No window to read. Click the message window first."); return nil }
            // Where the reader pointed, drawn onto the screenshot as a ring: Claude finds a
            // visible mark far more reliably than a percentage.
            var pointerHint = pointerOverride ?? fraction(of: pointer, in: window.frame, mainHeight: mainHeight)
            pointerHint?.marked = true
            guard let png = await screenshot(windowID: window.id, marker: pointerHint) else {
                await say("Could not capture the window. Check Screen Recording for Plainspeak.")
                return nil
            }
            payload.image_base64 = png.base64EncodedString()
            payload.pointer = pointerHint
            save(png: png, payload: payload)
        }
        return Grab(payload: payload, pointer: pointer)
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

    private func selectedText(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?, selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
              AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return String(text.prefix(40000))
    }

    /// Where the pointer is, as fractions of the window, or nil when it is outside it.
    private func fraction(of cocoaPoint: NSPoint, in frame: CGRect, mainHeight: CGFloat) -> Pointer? {
        // Cocoa puts the origin at the bottom left of the main screen; the window list at the top left.
        let p = CGPoint(x: cocoaPoint.x, y: mainHeight - cocoaPoint.y)
        guard frame.contains(p) else { return nil }
        let round = { (v: Double) in (v * 100).rounded() / 100 }
        return Pointer(x: round((p.x - frame.minX) / frame.width), y: round((p.y - frame.minY) / frame.height))
    }

    // MARK: - Screenshot

    /// The window alone at its full pixel size (Retina), without shadow or cursor,
    /// capped at 2560 px on the long edge and below the service's size limit.
    private func screenshot(windowID: CGWindowID, marker: Pointer?) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        var scale = CGFloat(filter.pointPixelScale)
        scale = min(scale, 2560 / max(rect.width, rect.height))
        for _ in 0..<6 {
            let config = SCStreamConfiguration()
            config.width = max(1, Int(rect.width * scale))
            config.height = max(1, Int(rect.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            guard var image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
            if let marker { image = mark(image, at: marker) }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            if png.count * 4 / 3 <= 7_500_000 { return png } // base64 must fit the service's limit
            scale *= 0.8
        }
        return nil
    }

    /// A pink ring with a white edge, readable on light and dark apps, with a clear centre
    /// so it hides as little of the message as possible.
    private func mark(_ image: CGImage, at p: Pointer) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let radius = max(14, CGFloat(max(w, h)) * 0.012), line = radius / 4
        let centre = CGPoint(x: CGFloat(p.x) * CGFloat(w), y: CGFloat(h) - CGFloat(p.y) * CGFloat(h)) // bitmap origin is bottom left
        let ring = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)); ctx.setLineWidth(line * 2); ctx.strokeEllipse(in: ring)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.18, blue: 0.58, alpha: 1)); ctx.setLineWidth(line); ctx.strokeEllipse(in: ring)
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
