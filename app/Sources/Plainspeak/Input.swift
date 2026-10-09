import AppKit
import Carbon.HIToolbox

/// Mouse side buttons. The assigned buttons stop acting as Back and Forward; with
/// Option, Control, Shift or Fn held (or Command on the front button) they behave normally.
final class SideButtons {
    struct Assignment: Codable, Equatable { var front = 4, back = 3 }
    enum Press { case read, correct, context }

    var onPress: ((Press) -> Void)?
    var onLearned: ((String) -> Void)?
    private(set) var buttons = SideButtons.load()
    private var tap: CFMachPort?
    private var consumed = Set<Int64>()
    private var learning: (which: String, chosen: Int64?)?
    private var learnTimeout: DispatchWorkItem?

    private static let file = Paths.state.appendingPathComponent("mouse.json")
    /// Your saved buttons, or the ones you set up for the Hammerspoon version.
    private static func load() -> Assignment {
        let hammerspoon = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/plainspeak-mouse.json")
        for url in [file, hammerspoon] {
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Assignment.self, from: data),
               (3...31).contains(saved.front), (3...31).contains(saved.back), saved.front != saved.back { return saved }
        }
        return Assignment()
    }

    /// Starts listening. Needs Accessibility; keeps retrying until it is granted.
    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue) | (1 << CGEventType.otherMouseDragged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<SideButtons>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: me)
        guard let tap else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The next side button pressed becomes the front or back button.
    func learn(_ which: String) {
        consumed = []
        learning = (which, nil)
        Toast.show("Press the \(which) side button now")
        learnTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.learning != nil else { return }
            self?.learning = nil
            Toast.show("Button setup timed out")
        }
        learnTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if let learn = learning {
            guard button >= 3 else { return Unmanaged.passUnretained(event) } // wheel, left and right are never rebound
            if type == .otherMouseDown { learning?.chosen = button; return nil }
            if type == .otherMouseUp, learn.chosen == button { finishLearning(learn.which, Int(button)) }
            return nil
        }
        // Remember the decision made on the way down until the button comes back up.
        if type != .otherMouseDown {
            let handled = consumed.contains(button)
            if type == .otherMouseUp { consumed.remove(button) }
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        guard button == buttons.front || button == buttons.back else { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        if flags.contains(.maskAlternate) || flags.contains(.maskControl) || flags.contains(.maskShift) || flags.contains(.maskSecondaryFn)
            || (flags.contains(.maskCommand) && button != buttons.back) { return Unmanaged.passUnretained(event) }
        consumed.insert(button)
        let press: Press = flags.contains(.maskCommand) ? .context : button == buttons.front ? .correct : .read
        DispatchQueue.main.async { [weak self] in self?.onPress?(press) } // leave the event callback before capturing
        return nil // no accidental browser Back or Forward
    }

    private func finishLearning(_ which: String, _ button: Int) {
        learning = nil
        learnTimeout?.cancel()
        if which == "front" {
            if buttons.back == button { buttons.back = buttons.front }
            buttons.front = button
        } else {
            if buttons.front == button { buttons.front = buttons.back }
            buttons.back = button
        }
        if let data = try? JSONEncoder().encode(buttons) { try? data.write(to: Self.file) }
        DispatchQueue.main.async { [weak self] in self?.onLearned?("Plainspeak \(which) button saved") }
    }
}

/// Global hotkeys through Carbon, which needs no extra permission.
final class Hotkeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var refs: [EventHotKeyRef] = []

    /// Control + Option + Command + the key.
    func register(_ keyCode: Int, _ action: @escaping () -> Void) {
        Self.installIfNeeded()
        let id = UInt32(Self.actions.count + 1)
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C5350), id: id) // "PLSP"
        if RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if let action = Hotkeys.actions[hotKeyID.id] { DispatchQueue.main.async(execute: action) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
