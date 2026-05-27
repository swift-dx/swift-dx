// swift-tools-version: 6.3
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftDX open source project
//
// Copyright (c) 2026 SwiftDX Contributors
// Licensed under Apache License v2.0. See LICENSE for license information.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


import PackageDescription
import Foundation

let integrityEnabled = ProcessInfo.processInfo.environment["SWIFTDX_INTEGRITY"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
]

var integrityPlugins: [Target.PluginUsage] = []
if integrityEnabled {
    packageDependencies.append(.package(path: "Tooling/Integrity"))
    integrityPlugins.append(.plugin(name: "IntegrityBuildPlugin", package: "Integrity"))
}

let package = Package(
    name: "swift-dx",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "DXCore", targets: ["DXCore"]),
        .library(name: "DXJetStream", targets: ["DXJetStream"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "DXCore",
            plugins: integrityPlugins
        ),
        .target(
            name: "DXJetStream",
            dependencies: [
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXCoreTests",
            dependencies: ["DXCore"],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXJetStreamTests",
            dependencies: ["DXJetStream"],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXJetStreamIntegration",
            dependencies: [
                "DXJetStream",
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "IntegrationTests/DXJetStreamIntegration",
            plugins: integrityPlugins
        ),
    ],
    swiftLanguageModes: [.v6]
)
