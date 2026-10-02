// swift-tools-version: 5.9
import PackageDescription

// Portable tests for the exact same pure Swift files compiled into both iOS targets.
let package = Package(
    name: "AutoDarkShiftCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "AutoDarkShiftCore", targets: ["AutoDarkShiftCore"])],
    targets: [
        .target(name: "AutoDarkShiftCore", path: ".",
                exclude: ["App", "PacketTunnel", "Platform/ScreenBrightnessSampler.swift", "Platform/LocalModeNotificationSink.swift", "KeepAlive", "Config", "docs", "tools", "Tests", "build",
                          "AutoDarkShift.xcodeproj", "README.md", "WORK_VPN_BRIGHTNESS.md", "MathModel v0.md",
                          "AutoDarkShift-8A9F2A91-84EA-4F70-98FD-84AB9036A6FB.jsonl",
                          "AutoDarkShift-18DF7D4B-8DEC-4D9B-A248-08F47E11221E.jsonl",
                          "AutoDarkShift-2D998352-F741-416C-824B-6A89A45CD2FD.jsonl"],
                sources: ["Shared", "Monitoring", "Platform/LoopbackMonitorTransport.swift"]),
        .testTarget(name: "AutoDarkShiftCoreTests", dependencies: ["AutoDarkShiftCore"], path: "Tests")
    ]
)
