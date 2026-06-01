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

import Testing
@testable import DXClickHouse

@Suite("ClickHouse per-query settings coverage")
struct ClickHouseSettingsCoverageTests {

    @Test("execute/scalar merge: caller settings survive alongside the deadline")
    func mergePreservesCallerSettings() {
        let caller = ClickHouseQuerySettings([
            .insertDeduplicationToken("tok-1"),
            ClickHouseQuerySetting(name: "max_threads", value: "4"),
        ])
        let merged = ClickHouseClient.injectMaxExecutionTime(into: caller, timeout: .seconds(5))
        let names = merged.entries.map(\.name)
        #expect(names.contains("insert_deduplication_token"))
        #expect(names.contains("max_threads"))
        #expect(names.contains("max_execution_time"))
    }

    @Test("an explicit max_execution_time is not overwritten or duplicated")
    func explicitDeadlineWins() {
        let caller = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "max_execution_time", value: "1"),
        ])
        let merged = ClickHouseClient.injectMaxExecutionTime(into: caller, timeout: .seconds(5))
        let deadlines = merged.entries.filter { $0.name == "max_execution_time" }
        #expect(deadlines.count == 1)
        #expect(deadlines.map(\.value) == ["1"])
    }

    @Test("a caller setting reaches the Query packet bytes for a SELECT-shaped statement")
    func settingReachesWire() throws {
        let settings = ClickHouseQuerySettings([
            ClickHouseQuerySetting(name: "async_insert", value: "1"),
        ])
        let bytes = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: settings,
            parameters: .empty,
            revision: ClickHouseQueryBuilder.revision
        )
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("async_insert"))
    }
}
