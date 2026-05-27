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
    name: "Integrity",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "Integrity", targets: ["Integrity"]),
        .executable(name: "IntegrityRunner", targets: ["IntegrityRunner"]),
        .plugin(name: "IntegrityBuildPlugin", targets: ["IntegrityBuildPlugin"]),
        .plugin(name: "IntegrityCommandPlugin", targets: ["IntegrityCommandPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "Integrity",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/Integrity"
        ),
        .executableTarget(
            name: "IntegrityRunner",
            dependencies: ["Integrity"],
            path: "Sources/IntegrityRunner"
        ),
        .plugin(
            name: "IntegrityBuildPlugin",
            capability: .buildTool(),
            dependencies: ["IntegrityRunner"],
            path: "Plugins/IntegrityBuildPlugin"
        ),
        .plugin(
            name: "IntegrityCommandPlugin",
            capability: .command(
                intent: .custom(
                    verb: "integrity-check",
                    description: "Run Integrity verification against the host package"
                )
            ),
            dependencies: ["IntegrityRunner"],
            path: "Plugins/IntegrityCommandPlugin"
        ),
        .testTarget(
            name: "IntegrityTests",
            dependencies: ["Integrity"],
            path: "Tests/IntegrityTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
