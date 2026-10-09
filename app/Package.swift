// swift-tools-version:5.9
// Plainspeak.app: the menu bar app. Build the whole bundle with scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "Plainspeak",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Plainspeak", path: "Sources/Plainspeak")]
)
