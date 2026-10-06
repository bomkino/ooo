// swift-tools-version: 6.0
//
// OOO — Obsess Over One. One slide, one camera, all the love.
//
//   RenderCore   GPU context, colour science, finishing, readback, video writing
//   BackdropKit  generative background engine (Metal, analytic, loopable)
//   StageKit     card renderer: curl and folds, surfaces, depth of field, shadows
//                (these three are the pitch.dog Studio engine, shared with
//                Drift, Galileo and Backdrop; see NOTICES.md)
//   OOOMotion    the camera's maths and choreography, the slide's entrances,
//                and the director's reasoning, in plain Swift (tested anywhere)
//   OOOCore      the slide, the voice, analysis, rendering and export
//   OOOStudio    the editor: stage, slide map, timeline, inspector, export
//   Updates      in-app updates from GitHub releases (Sparkle)
//
//   OOO          the Mac app
//   ooo-lab      headless renders and checks for review and CI
//
import PackageDescription

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

// The app loads Sparkle from Contents/Frameworks, where build-app.sh puts it.
let appLinker: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]

let package = Package(
    name: "OOO",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OOOMotion", targets: ["OOOMotion"]),
        .library(name: "OOOCore", targets: ["OOOCore"]),
        .library(name: "OOOStudio", targets: ["OOOStudio"]),
        .executable(name: "OOO", targets: ["OOOApp"]),
        .executable(name: "ooo-lab", targets: ["OOOLab"]),
    ],
    dependencies: [
        // In-app updates from GitHub releases (Updates module).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "RenderCore", swiftSettings: settings),
        .target(name: "BackdropKit", dependencies: ["RenderCore"], swiftSettings: settings),
        .target(name: "StageKit", dependencies: ["RenderCore", "BackdropKit"], swiftSettings: settings),
        .target(name: "OOOMotion", swiftSettings: settings),
        .target(name: "OOOCore", dependencies: ["OOOMotion", "RenderCore", "BackdropKit", "StageKit"], swiftSettings: settings),
        .target(name: "OOOStudio", dependencies: ["OOOCore"], swiftSettings: settings),
        .target(name: "Updates", dependencies: [.product(name: "Sparkle", package: "Sparkle")], swiftSettings: settings),
        .executableTarget(name: "OOOApp", dependencies: ["OOOStudio", "Updates"], swiftSettings: settings, linkerSettings: appLinker),
        .executableTarget(name: "OOOLab", dependencies: ["OOOCore"], swiftSettings: settings),
        .testTarget(name: "OOOMotionTests", dependencies: ["OOOMotion"], swiftSettings: settings),
        .testTarget(name: "OOOCoreTests", dependencies: ["OOOCore", "OOOMotion", "RenderCore", "StageKit"], swiftSettings: settings),
    ]
)
