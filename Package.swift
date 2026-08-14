// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Recut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Recut", targets: ["Recut"]),
        .executable(name: "RecutSample", targets: ["RecutSample"]),
    ],
    targets: [
        .executableTarget(
            name: "Recut",
            path: "Sources/Recut"
        ),
        .executableTarget(
            name: "RecutSample",
            path: "Sources/RecutSample"
        ),
    ]
)
