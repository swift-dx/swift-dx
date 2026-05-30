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

import DXClickHouse
import Foundation

// Shared scaffolding for the OperationsCoverage suites. Every suite in
// this folder drives the same live broker and uses the same env-var
// vocabulary already in use across the rest of the integration tests.
enum OperationsCoverageSupport {

    static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouse.connect(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    static func makeAsyncConnection() async throws -> AsyncClickHouseConnection {
        try await AsyncClickHouseConnection(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database
        )
    }

    static func uniqueTable(prefix: String) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").prefix(12)
        return "ops_cov_\(prefix)_\(suffix)"
    }
}
