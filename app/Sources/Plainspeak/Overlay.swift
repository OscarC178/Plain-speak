import AppKit
import WebKit

/// The answer panel: the service's overlay page in a borderless floating window that
/// opens beside the pointer and never takes focus from the app you are reading.
final class Overlay: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } } // lets Copy and text selection work
    private var panel: Panel?
    private var webView: WKWebView?
    private var dismissTap: CFMachPort?
    private var dismissSource: CFRunLoopSource?
    private var ready = false
    private var top: CGFloat = 0
    private var screen = NSRect.zero
    private let width: CGFloat = 460, gap: CGFloat = 24, startHeight: CGFloat = 200
    /// Debug builds only: save a picture of each finished panel here.
    private let saveDirectory = ProcessInfo.processInfo.environment["PLAINSPEAK_SAVE_CAPTURES"].map { URL(fileURLWithPath: $0) }

    func show(id: String, token: String, pointer: NSPoint) {
        close()
        ready = false
        screen = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // Beside the pointer, flipping to its left near the right edge, kept on screen.
        var x = pointer.x + gap
        if x + width > screen.maxX - 8 { x = pointer.x - gap - width }
        x = max(screen.minX + 8, min(x, screen.maxX - width - 8))
        top = min(screen.maxY - 8, max(screen.minY + startHeight + 8, pointer.y + 40))

        let controller = WKUserContentController()
        controller.add(self, name: "plainspeak")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let frame = NSRect(x: x, y: top - startHeight, width: width, height: startHeight)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground") // the page draws its own rounded card
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self

        let p = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = web
        p.orderFrontRegardless()
        panel = p
        webView = web
        // The token travels in the fragment, which is never sent in a request.
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(Paths.port)/overlay#id=\(id)&token=\(token)")!))
        watchDismiss()
    }

    func close() {
        if let tap = dismissTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = dismissSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        dismissTap = nil
        dismissSource = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "plainspeak")
        panel?.orderOut(nil)
        panel = nil
        webView = nil
    }

    // Messages from the page: close, ready, size and copy.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let text = body["text"] as? String ?? ""
        switch action {
        case "close": close()
        case "ready": ready = true; snapshotForDebug()
        case "size": if let height = Double(text) { resize(CGFloat(height)) }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default: break
        }
    }

    /// Fits the panel to its content, keeping the top edge still and the panel on screen.
    private func resize(_ height: CGFloat) {
        guard let panel else { return }
        let h = max(120, min(height, screen.height - 16))
        let y = max(screen.minY + 8, top - h)
        panel.setFrame(NSRect(x: panel.frame.minX, y: y, width: width, height: h), display: true)
    }

    /// Escape closes the panel at any time and is not passed on to the app underneath.
    /// Once the answer is ready, a click outside the panel closes it, and the click still lands.
    private func watchDismiss() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<Overlay>.fromOpaque(info!).takeUnretainedValue()
            return me.dismiss(type, event)
        }, userInfo: me) else { return }
        dismissTap = tap
        dismissSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), dismissSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func dismiss(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = dismissTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let panel else { return Unmanaged.passUnretained(event) }
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_EscapeCode) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [weak self] in self?.close() }
            return nil
        }
        if ready {
            // Event locations have their origin at the top left; window frames at the bottom left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let p = event.location
            let f = panel.frame
            let inside = p.x >= f.minX && p.x <= f.maxX && p.y >= mainHeight - f.maxY && p.y <= mainHeight - f.minY
            if !inside { DispatchQueue.main.async { [weak self] in self?.close() } }
        }
        return Unmanaged.passUnretained(event)
    }

    private func snapshotForDebug() {
        guard let dir = saveDirectory, let webView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            webView.takeSnapshot(with: nil) { image, _ in
                guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: dir.appendingPathComponent("panel-\(Int(Date().timeIntervalSince1970 * 1000)).png"))
            }
        }
    }
}

private let kVK_EscapeCode = 53
