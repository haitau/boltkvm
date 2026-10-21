// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoltKVM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "boltkvm", targets: ["boltkvm"]),
    ],
    targets: [
        .executableTarget(
            name: "boltkvm",
            path: "Sources/boltkvm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
