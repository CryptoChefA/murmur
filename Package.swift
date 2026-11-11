// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        // Headers for whisper.cpp. build.sh copies them in and builds the static library.
        .target(name: "CWhisper"),
        // Pure logic: text rules, stats, storage formats. No AppKit, fully checkable.
        .target(name: "MurmurCore"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CWhisper", "MurmurCore"],
            linkerSettings: [
                .unsafeFlags(["-Lvendor/lib"]),
                .linkedLibrary("whisper_all"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(name: "MurmurCheck", dependencies: ["MurmurCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
