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
import DXCore
import Foundation
import Testing

// Live-broker cover for per-query settings on the operation surfaces that
// gained a `settings:` parameter: execute, scalar, and stream. Gated on
// CH_INTEGRATION_HOST so it only runs when a live ClickHouse is wired.
@Suite(
    "DXClickHouse settings coverage integration",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseSettingsCoverageIntegration {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    private static func makeClient() async throws -> ClickHouseClient {
        try await ClickHouseClient(
            host: host, port: port,
            user: user, password: password, database: database
        )
    }

    @Test("scalar forwards a setting the server echoes back via getSetting")
    func scalarForwardsSetting() async throws {
        let client = try await Self.makeClient()
        let value = try await client.scalar(
            "SELECT toUInt64(getSetting('max_threads'))",
            as: UInt64.self,
            settings: ClickHouseQuerySettings([
                ClickHouseQuerySetting(name: "max_threads", value: "3"),
            ])
        )
        #expect(value == 3)
        await client.close()
    }

    @Test("execute forwards a setting: an unknown important setting is rejected")
    func executeForwardsSetting() async throws {
        let client = try await Self.makeClient()
        var caught: ClickHouseError = .reconnectExhausted(attempts: 0)
        do {
            try await client.execute(
                "SELECT 1",
                settings: ClickHouseQuerySettings([
                    ClickHouseQuerySetting(name: "this_setting_does_not_exist_anywhere", value: "1", important: true),
                ])
            )
        } catch let error {
            caught = error
        }
        switch caught {
        case .queryFailed(let exception):
            #expect(exception.code != 0)
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
            Issue.record("expected queryFailed, got \(caught)")
        }
        await client.close()
    }

    @Test("stream forwards a setting the server echoes back via getSetting")
    func streamForwardsSetting() async throws {
        let client = try await Self.makeClient()
        let collector = SettingCollector()
        let task = client.stream(
            "SELECT toUInt64(getSetting('max_threads')) AS value",
            as: SettingRow.self,
            settings: ClickHouseQuerySettings([
                ClickHouseQuerySetting(name: "max_threads", value: "7"),
            ]),
            handler: collector
        )
        await task.value
        let rows = await collector.snapshot()
        #expect(rows == [SettingRow(value: 7)])
        await client.close()
    }

    struct SettingRow: Codable, Sendable, Equatable {
        let value: UInt64
    }

    actor SettingCollector: DXMessageHandler {

        typealias Message = SettingRow
        typealias Failure = ClickHouseError

        private var rows: [SettingRow] = []

        func receive(_ message: SettingRow) async {
            rows.append(message)
        }

        func receive(error: ClickHouseError) async {
            rows.append(SettingRow(value: 999))
        }

        func snapshot() -> [SettingRow] {
            rows
        }
    }
}
