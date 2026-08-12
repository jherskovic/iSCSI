// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iSCSI",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure protocol logic: PDU codec, negotiation, auth, digests, session engine.
        // No sockets, no side effects — everything here is unit-testable and fuzzable.
        .target(
            name: "iSCSIKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Scriptable iSCSI target used by integration tests (and runnable standalone).
        .target(
            name: "MockTarget",
            dependencies: ["iSCSIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Daemon core as a library so it can be unit-tested; the executable is
        // a thin XPC/launchd launcher on top.
        .target(
            name: "iSCSIDaemon",
            dependencies: ["iSCSIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "iscsid",
            dependencies: ["iSCSIKit", "iSCSIDaemon"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "iscsictl",
            dependencies: [
                "iSCSIKit",
                // dext-attach drives DaemonCore + DextBridge directly.
                "iSCSIDaemon",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Fuzz harness: built normally it's a regression-replay tool;
        // scripts/fuzz.sh rebuilds it with -sanitize=fuzzer,address.
        .executableTarget(
            name: "pdu-fuzz",
            dependencies: ["iSCSIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "iSCSIKitTests",
            dependencies: ["iSCSIKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["iSCSIKit", "MockTarget", "iSCSIDaemon"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
