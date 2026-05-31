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
    name: "swift-dx-examples",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "JetStreamPublishAndFetch",
            dependencies: [
                .product(name: "DXJetStream", package: "swift-dx"),
            ],
            path: "Sources/JetStream/PublishAndFetch"
        ),
        .executableTarget(
            name: "JetStreamTestingPatterns",
            dependencies: [
                .product(name: "DXJetStream", package: "swift-dx"),
            ],
            path: "Sources/JetStream/TestingPatterns"
        ),
        .executableTarget(
            name: "RedisQuickStart",
            dependencies: [
                .product(name: "DXRedis", package: "swift-dx"),
                .product(name: "DXCore", package: "swift-dx"),
            ],
            path: "Sources/Redis/QuickStart"
        ),
        .executableTarget(
            name: "SQLiteQuickStart",
            dependencies: [
                .product(name: "DXSQLite", package: "swift-dx"),
            ],
            path: "Sources/SQLite/QuickStart"
        ),
    ],
    swiftLanguageModes: [.v6]
)
