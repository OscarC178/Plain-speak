import Foundation

/// Where Plainspeak keeps things. Personal state is shared with the command-line
/// version: ~/.plainspeak, or PLAINSPEAK_HOME when set.
enum Paths {
    static let state: URL = {
        let env = ProcessInfo.processInfo.environment["PLAINSPEAK_HOME"]
        let url = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".plainspeak")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    /// Contents/Resources inside Plainspeak.app.
    static var resources: URL { Bundle.main.resourceURL! }
    static var log: URL { state.appendingPathComponent("app.log") }
    static var port: Int { Int(ProcessInfo.processInfo.environment["PLAINSPEAK_PORT"] ?? "") ?? 8790 }

    /// The shared secret the service creates on first start.
    static func token() -> String? {
        (try? String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The service log, started afresh when it passes 1 MB. It holds times and errors, never captures.
    static func openLog() -> FileHandle? {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        if size > 1_000_000 || !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: log)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
