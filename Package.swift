// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iSCSI",
    platforms: [.macOS(.v15)],
    // The Xcode targets (iSCSIFSExtension, and anything else that links shared
    // protocol types) can only consume iSCSIKit if it is a *product*; as a bare
    // target it resolves to "Missing package product 'iSCSIKit'".
    products: [
        .library(name: "iSCSIKit", targets: ["iSCSIKit"]),
        // Same reason, for the Xcode `iscsid` target: the daemon executable is
        // built and signed by Xcode now, so that notarization covers it, and an
        // Xcode target can only link a package *product*. Named ...Kit to keep
        // it distinguishable from the `iscsid` executable that consumes it.
        .library(name: "iSCSIDaemonKit", targets: ["iSCSIDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // CRC32C via the hardware instruction (arm64 / SSE4.2), with a
        // slice-by-8 fallback. C because Swift exposes no way to emit the
        // CRC32C instruction, and the digest covers every byte on the wire.
        .target(name: "CCRC32C"),
        // Pure protocol logic: PDU codec, negotiation, auth, digests, session engine.
        // No sockets, no side effects — everything here is unit-testable and fuzzable.
        .target(
            name: "iSCSIKit",
            dependencies: ["CCRC32C"],
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
        // Local iSCSI target: loopback benchmarking without the transport
        // ceiling, plus faults (drop / corrupt / stall / target power loss)
        // that a real NAS cannot be asked to perform on demand.
        .executableTarget(
            name: "iscsi-target-sim",
            dependencies: [
                "iSCSIKit",
                "MockTarget",
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
