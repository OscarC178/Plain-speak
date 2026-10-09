import Foundation

/// Runs the bundled Plainspeak service (the local HTTP service plus the warm Claude
/// session) and restarts it if it stops. Its output goes to ~/.plainspeak/app.log.
final class Service {
    enum State: Equatable {
        case starting, ready, stopped
        case failed(String)
    }

    var onChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onChange?(state) } }
    }
    private var process: Process?
    private var stopping = false, restartWhenStopped = false
    private var recentCrashes: [Date] = []

    func start() {
        stopping = false
        let p = Process()
        p.executableURL = Paths.resources.appendingPathComponent("plainspeak-service")
        var env = ProcessInfo.processInfo.environment
        env["PLAINSPEAK_ROOT"] = Paths.resources.appendingPathComponent("service").path
        env["PLAINSPEAK_CLAUDE"] = Paths.resources.appendingPathComponent("claude").path
        env["PLAINSPEAK_PARENT_PID"] = String(getpid()) // the service exits if this app disappears
        p.environment = env
        p.currentDirectoryURL = Paths.state
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let log = Paths.openLog()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.read(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.exited(status) }
        }
        state = .starting
        do { try p.run(); process = p } catch { state = .failed("Could not start: \(error.localizedDescription)") }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    func restart() {
        recentCrashes = []
        if process == nil { start() } else { restartWhenStopped = true; stop() }
    }

    /// The service logs plain status lines; turn the ones that matter into a state.
    private func read(_ text: String) {
        for line in text.split(separator: "\n").map(String.init) {
            if line.contains("Claude session ready") { state = .ready }
            else if line.contains("already in use") { state = .failed("Port \(Paths.port) is in use. Stop any other copy of Plainspeak.") }
            else if let range = line.range(of: "Claude session could not start: ") { state = .failed(String(line[range.upperBound...])) }
            else if line.contains("Claude session failed") { state = .failed("The Claude session stopped. See the log.") }
        }
    }

    private func exited(_ status: Int32) {
        process = nil
        if restartWhenStopped { restartWhenStopped = false; start(); return }
        if stopping { state = .stopped; return }
        // Restart after a crash, but stop trying if it fails three times in a minute.
        recentCrashes = recentCrashes.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        if recentCrashes.count > 3 {
            if case .failed = state {} else { state = .failed("The service keeps stopping. See the log.") }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }
}
