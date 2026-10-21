// swift-tools-version: 6.0
import PackageDescription

var coreDependencies: [Target.Dependency] = []
var targets: [Target] = []

#if os(Windows)
coreDependencies.append("CWinAudio")
targets += [
    // WASAPI session enumeration and capture (COM, C++).
    .target(name: "CWinAudio", linkerSettings: [.linkedLibrary("Ole32"), .linkedLibrary("Mmdevapi")]),
    // Tray icon: settings, start/stop, autostart. GUI subsystem, no console window.
    .executableTarget(name: "KonspektTray", dependencies: ["KonspektCore"],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]),
]
#endif

targets += [
    .target(name: "KonspektCore", dependencies: coreDependencies),
    .executableTarget(name: "konspekt", dependencies: ["KonspektCore"]),
    .testTarget(name: "KonspektCoreTests", dependencies: ["KonspektCore"]),
]

let package = Package(
    name: "Konspekt",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v5]
)
