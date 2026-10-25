// swift-tools-version:5.9
//
// KawaNav iOS — the pure protocol layer (no CoreBluetooth required to build or test it).
//
// This package is the heart of the port: it decodes the Kawasaki BLE5 meter frames
// (the same protocol Rideology's app speaks) and builds the frames the app sends to
// the dash. It is 1:1 logic from the Android app, written so it can be built and unit-
// tested on any platform (macOS, iOS, and even Linux in CI), independent of Apple's
// Bluetooth stack.
//
// The CoreBluetooth wrapper (KawaBleManager) and the SwiftUI UI sit on top of this
// package and are gated with `#if canImport(CoreBluetooth)`, so the package still
// builds and its tests still run on non-Apple platforms.

import PackageDescription

let package = Package(
    name: "KawaNavProtocol",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "KawaNavProtocol",
            targets: ["KawaNavProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "KawaNavProtocol",
            path: "Sources/KawaNavProtocol"
        ),
        .testTarget(
            name: "KawaNavProtocolTests",
            dependencies: ["KawaNavProtocol"],
            path: "Tests/KawaNavProtocolTests"
        ),
    ]
)
