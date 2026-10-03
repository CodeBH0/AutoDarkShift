// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Local exports and build output are ignored by Git and may be absent in a fresh checkout.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let localArtifacts = (try? FileManager.default.contentsOfDirectory(atPath: packageDirectory))?.filter {
    $0 == "build" || $0 == "WORK_VPN_BRIGHTNESS.md" || ($0.hasPrefix("AutoDarkShift-") && $0.hasSuffix(".jsonl"))
} ?? []

// Portable tests for the exact same pure Swift files compiled into both iOS targets.
let package = Package(
    name: "AutoDarkShiftCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "AutoDarkShiftCore", targets: ["AutoDarkShiftCore"])],
    targets: [
        .target(name: "AutoDarkShiftCore", path: ".",
                exclude: ["App", "PacketTunnel", "Platform/ScreenBrightnessSampler.swift", "Platform/LocalModeNotificationSink.swift", "KeepAlive", "Config", "docs", "tools", "Tests", "archive",
                          "AutoDarkShift.xcodeproj", "README.md", "DEVELOPMENT.md", "AGENTS.md", "MathModel v1.md"] + localArtifacts,
                sources: ["Shared", "Monitoring", "Platform/LoopbackMonitorTransport.swift"]),
        .testTarget(name: "AutoDarkShiftCoreTests", dependencies: ["AutoDarkShiftCore"], path: "Tests")
    ]
)
