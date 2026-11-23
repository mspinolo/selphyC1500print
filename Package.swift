// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SELPHYCP1500Print",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SELPHYCP1500Print", targets: ["SELPHYCP1500Print"])
    ],
    targets: [
        .systemLibrary(
            name: "CLittleCMS",
            pkgConfig: "lcms2",
            providers: [.brew(["little-cms2"])]
        ),
        .target(
            name: "SELPHYICCReference",
            dependencies: ["CLittleCMS"],
            path: "Sources/SELPHYICCReference",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SELPHYCP1500Print",
            path: "Sources/SELPHYCP1500Print"
        ),
        .testTarget(
            name: "SELPHYCP1500PrintTests",
            dependencies: ["SELPHYCP1500Print", "SELPHYICCReference"],
            path: "Tests/SELPHYCP1500PrintTests"
        )
    ]
)
