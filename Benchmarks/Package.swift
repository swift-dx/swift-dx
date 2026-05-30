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
        .executableTarget(
            name: "ClickHouseAsyncBenchmark",
            dependencies: [
                .product(name: "DXClickHouse", package: "swift-dx"),
            ],
            path: "Sources/ClickHouseAsync",
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
            name: "ClickHousePoolBenchmark",
            dependencies: [
                .product(name: "DXClickHouse", package: "swift-dx"),
            ],
            path: "Sources/ClickHousePool",
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
            name: "ClickHouseStabilityBenchmark",
            dependencies: [
                .product(name: "DXClickHouse", package: "swift-dx"),
            ],
            path: "Sources/ClickHouseStability",
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
            name: "RedisBenchmark",
            dependencies: [
                .product(name: "DXRedis", package: "swift-dx"),
            ],
            path: "Sources/Redis",
            exclude: ["README.md"],
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
            name: "JSONSchemaBenchmark",
            dependencies: [
                .product(name: "DXJSONSchema", package: "swift-dx"),
                .product(name: "DXCore", package: "swift-dx"),
            ],
            path: "Sources/JSONSchema",
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
