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

let package = Package(
    name: "swift-dx-benchmarks",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    ],
    targets: [
        .executableTarget(
            name: "JetStreamBenchmark",
            dependencies: [
                .product(name: "DXJetStream", package: "swift-dx"),
            ],
            path: "Sources/JetStream",
            swiftSettings: [
                .unsafeFlags(
                    [
                        "-enforce-exclusivity=unchecked",
                        "-cross-module-optimization",
                    ],
                    .when(configuration: .release)
                ),
            ]
        ),
        .executableTarget(
            name: "ClickHouseBenchmark",
            dependencies: [
                .product(name: "DXClickHouse", package: "swift-dx"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/ClickHouse",
            swiftSettings: [
                .unsafeFlags(
                    [
                        "-enforce-exclusivity=unchecked",
                        "-cross-module-optimization",
                    ],
                    .when(configuration: .release)
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
