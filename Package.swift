// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SELPHYCP1500Print",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SELPHYCP1500Print", targets: ["SELPHYCP1500Print"])
    ],
    targets: [
        .executableTarget(
            name: "SELPHYCP1500Print",
            path: "Sources/SELPHYCP1500Print"
        ),
        .testTarget(
            name: "SELPHYCP1500PrintTests",
            dependencies: ["SELPHYCP1500Print"],
            path: "Tests/SELPHYCP1500PrintTests"
        )
    ]
)
