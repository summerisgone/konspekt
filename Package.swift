// swift-tools-version: 6.1
import PackageDescription

var coreDependencies: [Target.Dependency] = []
var targets: [Target] = []
var dependencies: [Package.Dependency] = []

#if os(macOS)
// Local speaker diarization (Core ML). No traits: skips the NeMo text-normalization binary.
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []))
coreDependencies.append(.product(name: "FluidAudio", package: "FluidAudio"))
#endif

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
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
