import AppKit
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

/// What Plainspeak needs, checked live while the setup window is open.
final class SetupModel: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var claude: Service.State = .starting
    @Published var startAtLogin = SMAppService.mainApp.status
    @Published var buttons = SideButtons.Assignment()
    var ready: Bool { accessibility && screenRecording && claude == .ready }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        startAtLogin = SMAppService.mainApp.status
    }
}

/// The actions behind the setup window's buttons, provided by the app.
struct SetupActions {
    var turnOnAccessibility: () -> Void
    var turnOnScreenRecording: () -> Void
    var reopen: () -> Void
    var checkClaude: () -> Void
    var setStartAtLogin: (Bool) -> Void
    var learn: (String) -> Void
    var done: () -> Void
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Plainspeak").font(.system(size: 24, weight: .bold))
                Text(model.ready ? "All set. Point at a message and press the back side button."
                                 : "Three things to switch on. The ticks update by themselves.")
                    .foregroundStyle(.secondary)
            }
            row(ok: model.accessibility, title: "Accessibility",
                detail: "Lets Plainspeak use your mouse side buttons and read the text you select.") {
                if !model.accessibility { Button("Turn on", action: actions.turnOnAccessibility) }
            }
            row(ok: model.screenRecording, title: "Screen Recording",
                detail: "Lets Plainspeak see the window you point at. Screenshots go only to Claude, through your own account. After turning it on, reopen Plainspeak.") {
                if !model.screenRecording {
                    Button("Turn on", action: actions.turnOnScreenRecording)
                    Button("Reopen Plainspeak", action: actions.reopen)
                }
            }
            row(ok: model.claude == .ready, title: "Claude", detail: claudeDetail) {
                if model.claude != .ready { Button("Check again", action: actions.checkClaude) }
            }
            Divider()
            Toggle(isOn: Binding(get: { model.startAtLogin == .enabled }, set: actions.setStartAtLogin)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Plainspeak when I log in").font(.system(size: 16, weight: .semibold))
                    if model.startAtLogin == .requiresApproval {
                        Text("macOS wants you to allow it in System Settings, Login Items.").foregroundStyle(.orange)
                    }
                }
            }
            .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mouse buttons").font(.system(size: 16, weight: .semibold))
                Text("Back side button (\(model.buttons.back)) reads a message. Front (\(model.buttons.front)) corrects it. Hold Command with the back button to add your notes and Drive.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Set front button…") { actions.learn("front") }
                    Button("Set back button…") { actions.learn("back") }
                }
            }
            HStack {
                Text("No mouse buttons? Control + Option + Command + R reads, + D corrects your selected draft.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done", action: actions.done).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 15))
        .lineSpacing(3)
        .padding(28)
        .frame(width: 580)
    }

    private var claudeDetail: String {
        switch model.claude {
        case .ready: return "Signed in. Plainspeak uses your Claude plan through Claude Code."
        case .starting: return "Starting the Claude session…"
        case .stopped: return "Stopped. Press Check again."
        case .failed(let reason):
            return reason.localizedCaseInsensitiveContains("log")
                ? "Not signed in. Open Terminal, type claude, sign in, then press Check again."
                : "Not working: \(reason)"
        }
    }

    private func row<Buttons: View>(ok: Bool, title: String, detail: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { buttons() }.padding(.top, 2)
            }
        }
    }
}

/// The window that holds the setup view, refreshing its ticks once a second while open.
final class SetupWindow: NSObject, NSWindowDelegate {
    let model = SetupModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show(actions: SetupActions) {
        model.refresh()
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Plainspeak Setup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: model, actions: actions))
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.delegate = self
            window = w
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        snapshotForDebug()
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    /// Debug launches only: save a picture of the window for checking. Uses the same capture as
    /// reading a message, because SwiftUI text does not show in an ordinary view snapshot.
    private func snapshotForDebug() {
        guard let dir = ProcessInfo.processInfo.environment["PLAINSPEAK_SAVE_CAPTURES"].map({ URL(fileURLWithPath: $0) }),
              let number = window?.windowNumber else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let found = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: found)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try? png.write(to: dir.appendingPathComponent("setup-\(Int(Date().timeIntervalSince1970)).png"))
            }
        }
    }
}
