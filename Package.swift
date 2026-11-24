// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SELPHYCP1500Print",
    platforms: [.macOS(.v14)],
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
            path: "Sources/SELPHYCP1500Print"
        ),
        .testTarget(
            name: "SELPHYCP1500PrintTests",
            dependencies: ["SELPHYCP1500Print", "SELPHYColorCore"],
            path: "Tests/SELPHYCP1500PrintTests"
        )
    ]
)
