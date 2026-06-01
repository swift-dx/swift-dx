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

import DXPostgres
import Foundation
import Testing

@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresRowDecoderIntegrationTests {

    struct Account: Decodable, Equatable, Sendable {
        let id: Int
        let name: String
        let balance: Decimal
        let active: Bool
        let token: UUID
        let nickname: String?
    }

    struct Profile: Codable, Equatable, Sendable {
        let theme: String
        let notifications: Bool
    }

    struct AccountWithProfile: Decodable, Equatable, Sendable {
        let id: Int
        let profile: Profile
    }

    @Test func mapsRowToStruct() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let token = UUID()
            let row = try await postgres.query(
                "SELECT 42::int4 AS id, 'Ada'::text AS name, 12.50::numeric AS balance, true AS active, $1::uuid AS token, NULL::text AS nickname",
                binding: [token]
            ).rows[0]
            let account = try row.decode(Account.self)
            let expectedBalance = Decimal(string: "12.50") ?? Decimal.zero
            #expect(account == Account(id: 42, name: "Ada", balance: expectedBalance, active: true, token: token, nickname: nil))
        }
    }

    @Test func mapsNarrowIntegerFields() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            struct Sizes: Decodable, Equatable { let small: Int16; let medium: Int32; let large: Int64 }
            let row = try await postgres.query("SELECT 7::int2 AS small, 70000::int4 AS medium, 9000000000::int8 AS large, $1::int AS forceExtended", binding: [1]).rows[0]
            #expect(try row.decode(Sizes.self) == Sizes(small: 7, medium: 70000, large: 9_000_000_000))
        }
    }

    @Test func mapsNestedStructFromJSONColumn() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let profile = Profile(theme: "dark", notifications: true)
            let row = try await postgres.query("SELECT 1::int4 AS id, $1::jsonb AS profile", binding: [PostgresJSON(profile)]).rows[0]
            #expect(try row.decode(AccountWithProfile.self) == AccountWithProfile(id: 1, profile: profile))
        }
    }

    @Test func mapsSingleColumnScalar() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT 99::int4 AS n, $1::int AS forceExtended", binding: [1]).rows[0]
            #expect(try row.decode(Int.self) == 99)
        }
    }
}
