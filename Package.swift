// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Garlo",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GarloCore", targets: ["GarloCore"]),
        .executable(name: "GarloApp", targets: ["GarloApp"]),
        .executable(name: "garlo", targets: ["garlo"]),
        .executable(name: "GarloHelper", targets: ["GarloHelper"]),
    ],
    targets: [
        // Samplers, store, rules and findings. No UI imports, so every rule
        // is unit-testable against recorded fixtures.
        .target(
            name: "GarloCore",
            path: "Sources/GarloCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        // The menu-bar app.
        .executableTarget(
            name: "GarloApp",
            dependencies: ["GarloCore"],
            path: "Sources/GarloApp"
        ),
        // Command-line front end over the same core: live sampling,
        // fixture capture and replay.
        .executableTarget(
            name: "garlo",
            dependencies: ["GarloCore"],
            path: "Sources/GarloCLI"
        ),
        // The privileged daemon (M4), bundled into Garlo.app and registered
        // through SMAppService when the user asks for it.
        .executableTarget(
            name: "GarloHelper",
            dependencies: ["GarloCore"],
            path: "Sources/GarloHelper"
        ),
        .testTarget(
            name: "GarloCoreTests",
            dependencies: ["GarloCore"],
            path: "Tests/GarloCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
