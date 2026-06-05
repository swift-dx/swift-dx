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
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
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
        .library(name: "DXClickHouse", targets: ["DXClickHouse"]),
        .library(name: "DXRedis", targets: ["DXRedis"]),
        .library(name: "DXPostgres", targets: ["DXPostgres"]),
        .library(name: "DXJSONSchema", targets: ["DXJSONSchema"]),
        .library(name: "DXSQLite", targets: ["DXSQLite"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "DXCore",
            exclude: ["README.md"],
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
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            exclude: ["README.md"],
            plugins: integrityPlugins
        ),
        .target(
            name: "DXRedis",
            dependencies: [
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            exclude: ["README.md"],
            plugins: integrityPlugins
        ),
        .target(
            name: "DXPostgres",
            dependencies: [
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            exclude: ["README.md"],
            plugins: integrityPlugins
        ),
        .target(
            name: "DXClickHouse",
            dependencies: [
                "DXCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            exclude: ["README.md"],
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
        .testTarget(
            name: "DXRedisTests",
            dependencies: [
                "DXRedis",
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "MetricsTestKit", package: "swift-metrics"),
            ],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXRedisIntegration",
            dependencies: [
                "DXRedis",
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "IntegrationTests/DXRedisIntegration",
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXClickHouseTests",
            dependencies: [
                "DXClickHouse",
                "DXCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "DXClickHouseIntegration",
            dependencies: [
                "DXClickHouse",
                "DXCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "IntegrationTests/DXClickHouseIntegration"
        ),
        .target(
            name: "DXJSONSchema",
            dependencies: [
                "DXCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            exclude: ["README.md"],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXJSONSchemaTests",
            dependencies: [
                "DXJSONSchema",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXJSONSchemaComplianceTests",
            dependencies: [
                "DXJSONSchema",
                "DXCore",
            ],
            resources: [
                .copy("Resources/suite"),
            ],
            plugins: integrityPlugins
        ),
        .target(
            name: "CSQLite",
            path: "Sources/DXSQLite/CSQLite",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_DEFAULT_FOREIGN_KEYS", to: "1"),
                .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
                .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
                .define("SQLITE_USE_ALLOCA"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_FTS4"),
                .define("SQLITE_ENABLE_FTS3_PARENTHESIS"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_ENABLE_GEOPOLY"),
                .define("SQLITE_ENABLE_RBU"),
                .define("SQLITE_ENABLE_SESSION"),
                .define("SQLITE_ENABLE_PREUPDATE_HOOK"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_ENABLE_COLUMN_METADATA"),
                .define("SQLITE_ENABLE_DBSTAT_VTAB"),
                .define("SQLITE_ENABLE_BYTECODE_VTAB"),
                .define("SQLITE_ENABLE_STMT_SCANSTATUS"),
                .define("SQLITE_ENABLE_NORMALIZE"),
                .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_ENABLE_CARRAY"),
                .define("SQLITE_ENABLE_PERCENTILE"),
                .define("SQLITE_ENABLE_OFFSET_SQL_FUNC"),
                .define("SQLITE_ENABLE_DESERIALIZE"),
                .define("SQLITE_ENABLE_SETLK_TIMEOUT"),
                .define("SQLITE_ENABLE_UNLOCK_NOTIFY"),
                .define("SQLITE_ENABLE_API_ARMOR"),
            ],
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "DXSQLite",
            dependencies: [
                "DXCore",
                "CSQLite",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/DXSQLite/DXSQLite",
            exclude: ["README.md"],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXSQLiteTests",
            dependencies: [
                "DXSQLite",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            plugins: integrityPlugins
        ),
        .testTarget(
            name: "DXSQLitePublicAPITests",
            dependencies: [
                "DXSQLite",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            plugins: integrityPlugins
        ),
    ],
    swiftLanguageModes: [.v6]
)
