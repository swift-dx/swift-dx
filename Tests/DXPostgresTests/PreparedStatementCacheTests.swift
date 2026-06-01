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

@testable import DXPostgres

@Suite struct PreparedStatementCacheTests {

    @Test func firstUseParsesAndPrepares() {
        var cache = PreparedStatementCache()
        let plan = cache.plan(for: "SELECT 1")
        #expect(plan.needsParse)
        if case .parseAndPrepare = plan { } else { Issue.record("expected parseAndPrepare") }
    }

    @Test func repeatUseReusesNameAndSkipsParse() {
        var cache = PreparedStatementCache()
        let first = cache.plan(for: "SELECT 1")
        let second = cache.plan(for: "SELECT 1")
        #expect(second == .prepared(name: first.statementName))
        #expect(!second.needsParse)
    }

    @Test func distinctStatementsGetDistinctNames() {
        var cache = PreparedStatementCache()
        let first = cache.plan(for: "SELECT 1").statementName
        let second = cache.plan(for: "SELECT 2").statementName
        #expect(first != second)
    }

    @Test func evictionForcesReparse() {
        var cache = PreparedStatementCache()
        _ = cache.plan(for: "SELECT 1")
        cache.evict("SELECT 1")
        #expect(cache.plan(for: "SELECT 1").needsParse)
    }

    @Test func beyondLimitFallsBackToEphemeral() {
        var cache = PreparedStatementCache(limit: 2)
        _ = cache.plan(for: "SELECT 1")
        _ = cache.plan(for: "SELECT 2")
        #expect(cache.plan(for: "SELECT 3") == .ephemeral)
    }

    @Test func ephemeralUsesUnnamedStatementButStillParses() {
        var cache = PreparedStatementCache(limit: 0)
        let plan = cache.plan(for: "SELECT 1")
        #expect(plan == .ephemeral)
        #expect(plan.statementName == "")
        #expect(plan.needsParse)
    }
}
