import AppKit
import WebKit

/// The settings window: the service's settings page in an ordinary window.
/// Changes save themselves and apply from the next capture, so there is no Save button.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        guard let token = Paths.token() else { Toast.show("Plainspeak is still starting. Try again in a moment."); return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Plainspeak Settings"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 520, height: 400)
            w.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.13, alpha: 1)
            w.contentView = WKWebView(frame: w.contentRect(forFrameRect: w.frame))
            w.center()
            w.delegate = self
            window = w
        }
        // Reload each time so the page shows what is saved now. The token stays in the fragment.
        (window?.contentView as? WKWebView)?.load(URLRequest(url: URL(string: "http://127.0.0.1:\(Paths.port)/settings-page#token=\(token)")!))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Settings and styles through the local service, for the menu's quick style switch.
enum SettingsAPI {
    struct Choice { let id: String; let name: String }

    /// Current settings and style lists. Local and fast, so the menu can wait briefly for it.
    static func load() -> (settings: [String: Any], read: [Choice], draft: [Choice])? {
        guard let data = request("GET", body: nil),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settings = json["settings"] as? [String: Any], let styles = json["styles"] as? [String: Any] else { return nil }
        let list = { (kind: String) in (styles[kind] as? [[String: Any]] ?? []).compactMap { s -> Choice? in
            guard let id = s["id"] as? String, let name = s["name"] as? String else { return nil }
            return Choice(id: id, name: name)
        } }
        return (settings, list("read"), list("draft"))
    }

    /// Changes one setting and saves. Returns an error message, or nil when saved.
    static func set(_ key: String, to value: String) -> String? {
        guard var settings = load()?.settings else { return "Plainspeak's service is not running." }
        settings[key] = value
        guard let body = try? JSONSerialization.data(withJSONObject: settings) else { return "Could not save." }
        guard let data = request("PUT", body: body) else { return "Could not save." }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["error"] as? String
    }

    private static func request(_ method: String, body: Data?) -> Data? {
        guard let token = Paths.token() else { return nil }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Paths.port)/settings")!, timeoutInterval: 1)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = body }
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in result = data; done.signal() }.resume()
        _ = done.wait(timeout: .now() + 1.5)
        return result
    }
}
