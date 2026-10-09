import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let service = Service()
    private let capture = Capture()
    private let overlay = Overlay()
    private let sideButtons = SideButtons()
    private let hotkeys = Hotkeys()
    private let settingsWindow = SettingsWindow()
    private let readStyles = NSMenu(), draftStyles = NSMenu()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuIcon.make()
        statusItem.button?.toolTip = "Plainspeak"

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Read the message", #selector(read), key: "r"))
        menu.addItem(item("Correct the message", #selector(correct)))
        menu.addItem(item("Correct my selected draft", #selector(draft), key: "d"))
        menu.addItem(item("Read with my notes and Drive", #selector(context), key: "g"))
        menu.addItem(item("Close panel", #selector(closePanel)))
        menu.addItem(.separator())
        menu.addItem(submenu("Reading style", readStyles))
        menu.addItem(submenu("Draft style", draftStyles))
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", hotkey: false))
        menu.addItem(.separator())
        menu.addItem(item("Set front mouse button…", #selector(learnFront)))
        menu.addItem(item("Set back mouse button…", #selector(learnBack)))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(item("Restart Claude session", #selector(restartService)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Plainspeak", #selector(quit), key: "q", hotkey: false))
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()

        service.onChange = { [weak self] state in self?.show(state) }
        service.start()

        // Ask macOS for the two permissions up front; each prompt appears only while it is missing.
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        // Front side button corrects, back reads, Command + back adds notes and Drive.
        sideButtons.onPress = { [weak self] press in
            switch press {
            case .read: self?.run(.read)
            case .correct: self?.run(.correct)
            case .context: self?.run(.read, context: true)
            }
        }
        sideButtons.onLearned = { Toast.show($0) }
        sideButtons.start()
        hotkeys.register(kVK_ANSI_R) { [weak self] in self?.run(.read) }
        hotkeys.register(kVK_ANSI_D) { [weak self] in self?.run(.draft) }
        hotkeys.register(kVK_ANSI_G) { [weak self] in self?.run(.read, context: true) }
        startDebugTrigger()
    }

    func applicationWillTerminate(_ notification: Notification) { service.stop() }

    /// Grabs the screen, sends it to the service, and opens the panel for the answer.
    private func run(_ mode: Mode, context: Bool = false) {
        Task {
            guard let grab = await capture.grab(mode: mode, context: context) else { return }
            guard let token = Paths.token() else { await toast("Plainspeak is still starting. Try again in a moment."); return }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Paths.port)/capture")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONEncoder().encode(grab.payload)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                await MainActor.run {
                    if status == 202, let id = json?["request_id"] as? String {
                        self.overlay.show(id: id, token: token, pointer: grab.pointer)
                    } else {
                        Toast.show(json?["error"] as? String ?? "Plainspeak is not ready yet.")
                    }
                }
            } catch {
                await toast("Plainspeak's service is not running. Choose Restart Claude session from the menu.")
            }
        }
    }

    @MainActor private func toast(_ text: String) { Toast.show(text) }

    // MARK: - Styles in the menu

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// Rebuilt each time the menu opens, so the tick always shows what is saved.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        guard let loaded = SettingsAPI.load() else {
            for m in [readStyles, draftStyles] { m.removeAllItems(); m.addItem(NSMenuItem(title: "Plainspeak is starting…", action: nil, keyEquivalent: "")) }
            return
        }
        fill(readStyles, loaded.read, current: loaded.settings["read_style"] as? String, key: "read_style")
        fill(draftStyles, loaded.draft, current: loaded.settings["draft_style"] as? String, key: "draft_style")
    }

    private func fill(_ menu: NSMenu, _ choices: [SettingsAPI.Choice], current: String?, key: String) {
        menu.removeAllItems()
        for choice in choices {
            let entry = item(choice.name, #selector(pickStyle(_:)))
            entry.state = choice.id == current ? .on : .off
            entry.representedObject = [key, choice.id, choice.name]
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Add a custom style…", #selector(openSettings)))
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 3 else { return }
        if let error = SettingsAPI.set(info[0], to: info[1]) { Toast.show("Not saved: \(error)") }
        else { Toast.show("\(info[0] == "read_style" ? "Reading" : "Draft") style: \(info[2])") }
    }

    /// Menu bar apps have no Edit menu, which leaves copy and paste dead in text fields.
    /// This one is never shown; it only gives the settings window its shortcuts.
    private func installEditMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        let appMenu = NSMenu(), edit = NSMenu(title: "Edit")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appItem.submenu = appMenu
        editItem.submenu = edit
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String = "", hotkey: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        // Shown for reference: the global hotkeys are Control + Option + Command + the key.
        if hotkey && !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option, .command] }
        return item
    }

    private func show(_ state: Service.State) {
        switch state {
        case .starting: statusLine.title = "Starting Claude…"
        case .ready: statusLine.title = "Ready"
        case .stopped: statusLine.title = "Stopped"
        case .failed(let reason): statusLine.title = "Not working: \(reason)"
        }
        // A dimmed icon means captures will not work right now.
        statusItem.button?.appearsDisabled = state != .ready
    }

    /// Debug launches only (PLAINSPEAK_DEBUG=1): lets a test script trigger a capture
    /// without pressing anything. The object is a mode, optionally with a pointer: "read@0.43,0.30".
    private func startDebugTrigger() {
        guard ProcessInfo.processInfo.environment["PLAINSPEAK_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.oscarc.plainspeak.debug.capture"), object: nil, queue: .main) { [weak self] note in
            let parts = (note.object as? String ?? "read").split(separator: "@").map(String.init)
            let coords = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            self?.capture.pointerOverride = coords.count == 2 ? Capture.Pointer(x: coords[0], y: coords[1]) : nil
            switch parts[0] {
            case "correct": self?.run(.correct)
            case "draft": self?.run(.draft)
            case "context": self?.run(.read, context: true)
            case "close": self?.overlay.close()
            case "settings": self?.settingsWindow.show()
            default: self?.run(.read)
            }
        }
    }

    @objc private func read() { run(.read) }
    @objc private func correct() { run(.correct) }
    @objc private func draft() { run(.draft) }
    @objc private func context() { run(.read, context: true) }
    @objc private func closePanel() { overlay.close() }
    @objc private func learnFront() { sideButtons.learn("front") }
    @objc private func learnBack() { sideButtons.learn("back") }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func openLog() { NSWorkspace.shared.open(Paths.log) }
    @objc private func restartService() { service.restart() }
    @objc private func quit() { NSApp.terminate(nil) }
}
