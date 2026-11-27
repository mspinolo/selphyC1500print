// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = []

let package = Package(
    name: "SELPHYCP1500Print",
    // macOS 27.0 for now; 27.2 (owner's target) as soon as the CI runner image runs 27.2, so that
    // the macOS tests keep running (the workflow says when).
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "SELPHYCP1500Print", targets: ["SELPHYCP1500Print"])
    ],
    targets: [
        // Vendored LittleCMS (see Sources/CLittleCMS/VENDORED.md): identical numerical
        // behaviour on Linux and macOS, no Homebrew dependency.
        .target(
            name: "CLittleCMS",
            path: "Sources/CLittleCMS",
            exclude: ["LICENSE", "VENDORED.md"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("HasTHREADS", to: "1"),
                .define("HAVE_GMTIME_R", to: "1")
            ]
        ),
        // Portable colour core (also built and tested on Linux through CMakeLists.txt).
        .target(
            name: "SELPHYColorCore",
            dependencies: ["CLittleCMS"],
            path: "Sources/SELPHYColorCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SELPHYCP1500Print",
            dependencies: ["SELPHYColorCore"],
            path: "Sources/SELPHYCP1500Print",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SELPHYCP1500PrintTests",
            dependencies: ["SELPHYCP1500Print", "SELPHYColorCore"],
            path: "Tests/SELPHYCP1500PrintTests",
            swiftSettings: swiftSettings
        )
    ],
    // Step 1 of the move to Swift 6: new tools and SDK, Swift 5 language mode; step 2 turns on
    // the Swift 6 mode (complete concurrency checking).
    swiftLanguageModes: [.v5]
)
