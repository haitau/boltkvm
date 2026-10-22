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
        // Everything reusable: wire protocol, server, client, renderer, audio,
        // virtual display. Both the CLI and the app are thin shells over this.
        .target(
            name: "BoltKVMCore",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/BoltKVMCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "boltkvm",
            dependencies: ["BoltKVMCore"],
            path: "Sources/boltkvm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The single app bundle. Packaging/build-app.sh turns this into
        // BoltKVM.app; the role is chosen at first run, not by which binary.
        .executableTarget(
            name: "BoltKVMApp",
            dependencies: ["BoltKVMCore"],
            path: "Sources/BoltKVMApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
