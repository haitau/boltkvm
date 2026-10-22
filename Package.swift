// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoltKVM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "boltkvm", targets: ["boltkvm"]),
    ],
    targets: [
        // Vendor of the private CGVirtualDisplay glue (see THIRD_PARTY_NOTICES.md).
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "boltkvm",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/boltkvm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
