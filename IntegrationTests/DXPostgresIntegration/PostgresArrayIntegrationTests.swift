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

// A bound parameter forces the extended protocol, so the array columns return in
// binary, which is the supported decoding path.
@Suite(.enabled(if: PostgresIntegration.isEnabled)) struct PostgresArrayIntegrationTests {

    @Test func decodesIntegerAndTextArrays() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query(
                "SELECT ARRAY[10, 20, 30]::int4[] AS nums, ARRAY['ada', 'alan']::text[] AS names, $1::int AS forceExtended",
                binding: [1]
            ).rows[0]
            #expect(try row.decodeArray(Int.self, named: "nums") == [10, 20, 30])
            #expect(try row.decodeArray(String.self, named: "names") == ["ada", "alan"])
        }
    }

    @Test func decodesBigIntAndUUIDArrays() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let first = UUID()
            let second = UUID()
            let row = try await postgres.query(
                "SELECT ARRAY[$1::uuid, $2::uuid]::uuid[] AS ids, ARRAY[9000000000, -9000000000]::int8[] AS bigs",
                binding: [first, second]
            ).rows[0]
            #expect(try row.decodeArray(UUID.self, named: "ids") == [first, second])
            #expect(try row.decodeArray(Int64.self, named: "bigs") == [9_000_000_000, -9_000_000_000])
        }
    }

    @Test func decodesEmptyArray() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ARRAY[]::int4[] AS empty, $1::int AS forceExtended", binding: [1]).rows[0]
            #expect(try row.decodeArray(Int.self, named: "empty") == [])
        }
    }

    @Test func decodesArrayWithNullElements() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ARRAY[1, NULL, 3]::int4[] AS sparse, $1::int AS forceExtended", binding: [1]).rows[0]
            #expect(try row.decodeNullableArray(Int.self, named: "sparse") == [.value(1), .sqlNull, .value(3)])
        }
    }

    @Test func decodesTextFormatArraysFromSimpleQuery() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ARRAY[10, 20, 30]::int4[] AS nums, ARRAY['a', 'b,c', 'quote\"x']::text[] AS tags, ARRAY[1, NULL, 3]::int4[] AS sparse").rows[0]
            #expect(try row.decodeArray(Int.self, named: "nums") == [10, 20, 30])
            #expect(try row.decodeArray(String.self, named: "tags") == ["a", "b,c", "quote\"x"])
            #expect(try row.decodeNullableArray(Int.self, named: "sparse") == [.value(1), .sqlNull, .value(3)])
        }
    }

    @Test func decodesEmptyTextArray() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ARRAY[]::int4[] AS empty").rows[0]
            #expect(try row.decodeArray(Int.self, named: "empty") == [])
        }
    }

    @Test func nonNullableArrayDecodeRejectsNullElement() async throws {
        try await Postgres.withClient(PostgresIntegration.makeConfiguration()) { postgres in
            let row = try await postgres.query("SELECT ARRAY[1, NULL, 3]::int4[] AS sparse, $1::int AS forceExtended", binding: [1]).rows[0]
            #expect(throws: PostgresError.self) {
                try row.decodeArray(Int.self, named: "sparse")
            }
        }
    }
}
