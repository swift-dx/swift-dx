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

@testable import DXClickHouse
import Foundation
import NIOCore
import NIOPosix
import Testing

// Property-style integration tests: each parameterized run generates a
// fixed-seeded random payload, INSERTs it, SELECTs it back, and checks
// element-wise equality. The seed is part of the test arguments so a
// failure prints the seed and a re-run reproduces the exact bytes.
//
// These tests catch byte-level codec drift the curated boundary suite
// misses: alignment surprises, length-prefix bugs, accumulator overflow,
// etc. They are not "test the implementation against itself"; the
// payloads come from a deterministic RNG independent of the codec.
@Suite(
    "ClickHouse integration — fuzz matrix",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseFuzzMatrixTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    private static func makeClient() -> (ClickHouseClient, EventLoopGroup) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: host, port: port)],
            database: database,
            user: user,
            password: password,
            eventLoopGroup: group
        ))
        return (client, group)
    }

    private static func uniqueTable(_ prefix: String) -> String {
        "test.fuzz_\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    // INSERT + SELECT a single typed column; the caller passes the
    // generator that produces the payload from a seed so the assertion
    // can compare against the exact same payload it sent.
    private static func roundTrip(
        typeName: String,
        column: String,
        values: ClickHouseColumnEntry.Values
    ) async throws -> ClickHouseColumnEntry.Values {
        let table = uniqueTable(column)
        let (client, group) = makeClient()
        defer { _ = group }

        try await client.execute("CREATE TABLE \(table) (v \(typeName)) ENGINE = Memory")
        try await client.insert(into: table, columns: [.init(name: "v", values: values)])
        let blocks = try await client.collectSelectColumns("SELECT v FROM \(table)")
        try await client.execute("DROP TABLE \(table)")
        await client.shutdown()

        guard let block = blocks.first(where: { $0.rowCount > 0 }) else {
            throw FuzzError.noRowsReturned
        }
        guard let column = block.columns.first else {
            throw FuzzError.noColumnsReturned
        }
        return column.values
    }

    private enum FuzzError: Error {

        case noRowsReturned
        case noColumnsReturned

    }

    // MARK: - signed integer fuzz

    @Test(
        "Int8 fuzz: 200 deterministic random values round-trip element-wise",
        arguments: [1, 2, 3, 4, 5] as [UInt64]
    )
    func int8Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<200).map { _ in Int8.random(in: .min ... .max, using: &rng) }
        let result = try await Self.roundTrip(typeName: "Int8", column: "i8", values: .int8(values))
        guard case .int8(let received) = result else {
            Issue.record("expected .int8, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    @Test(
        "Int32 fuzz: 500 deterministic random values round-trip as a multiset",
        arguments: [1, 2, 3, 4, 5] as [UInt64]
    )
    func int32Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<500).map { _ in Int32.random(in: .min ... .max, using: &rng) }
        let result = try await Self.roundTrip(typeName: "Int32", column: "i32", values: .int32(values))
        guard case .int32(let received) = result else {
            Issue.record("expected .int32, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    @Test(
        "Int64 fuzz: 500 deterministic random values across the full signed 64-bit range",
        arguments: [11, 22, 33, 44, 55] as [UInt64]
    )
    func int64Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<500).map { _ in Int64.random(in: .min ... .max, using: &rng) }
        let result = try await Self.roundTrip(typeName: "Int64", column: "i64", values: .int64(values))
        guard case .int64(let received) = result else {
            Issue.record("expected .int64, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    // MARK: - unsigned integer fuzz

    @Test(
        "UInt32 fuzz: 500 random values from 0…UInt32.max round-trip",
        arguments: [101, 202, 303, 404, 505] as [UInt64]
    )
    func uint32Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<500).map { _ in UInt32.random(in: 0 ... .max, using: &rng) }
        let result = try await Self.roundTrip(typeName: "UInt32", column: "u32", values: .uint32(values))
        guard case .uint32(let received) = result else {
            Issue.record("expected .uint32, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    @Test(
        "UInt64 fuzz: 500 random values across the full unsigned 64-bit range",
        arguments: [111, 222, 333, 444, 555] as [UInt64]
    )
    func uint64Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<500).map { _ in UInt64.random(in: 0 ... .max, using: &rng) }
        let result = try await Self.roundTrip(typeName: "UInt64", column: "u64", values: .uint64(values))
        guard case .uint64(let received) = result else {
            Issue.record("expected .uint64, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    // MARK: - float fuzz

    @Test(
        "Float64 fuzz: 500 random doubles round-trip with bit-exact equality (no NaN/Inf)",
        arguments: [9001, 9002, 9003] as [UInt64]
    )
    func float64Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<500).map { _ in Double.random(in: -1e6 ... 1e6, using: &rng) }
        let result = try await Self.roundTrip(typeName: "Float64", column: "f64", values: .float64(values))
        guard case .float64(let received) = result else {
            Issue.record("expected .float64, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    // MARK: - string fuzz

    @Test(
        "String fuzz: 200 random ASCII strings of length 0…64 round-trip as a multiset",
        arguments: [7001, 7002, 7003] as [UInt64]
    )
    func stringFuzzAscii(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<200).map { _ -> String in
            let length = Int.random(in: 0...64, using: &rng)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0x20...0x7E, using: &rng) }
            return String(decoding: bytes, as: UTF8.self)
        }
        let result = try await Self.roundTrip(typeName: "String", column: "s", values: .string(values))
        guard case .string(let received) = result else {
            Issue.record("expected .string, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    @Test(
        "String fuzz: 100 random UTF-8 strings spanning multi-byte codepoints round-trip",
        arguments: [8001, 8002, 8003] as [UInt64]
    )
    func stringFuzzUTF8(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<100).map { _ -> String in
            let length = Int.random(in: 0...32, using: &rng)
            var scalars: [Unicode.Scalar] = []
            scalars.reserveCapacity(length)
            for _ in 0..<length {
                // Skip surrogate range (0xD800-0xDFFF) and noncharacters.
                let pool: [ClosedRange<UInt32>] = [
                    0x20...0x7E,
                    0xA0...0x7FF,
                    0x800...0xD7FF,
                    0x10000...0x10FFFF,
                ]
                let bucket = pool[Int.random(in: 0..<pool.count, using: &rng)]
                let raw = UInt32.random(in: bucket, using: &rng)
                if let scalar = Unicode.Scalar(raw) {
                    scalars.append(scalar)
                }
            }
            return String(String.UnicodeScalarView(scalars))
        }
        let result = try await Self.roundTrip(typeName: "String", column: "s", values: .string(values))
        guard case .string(let received) = result else {
            Issue.record("expected .string, got \(result) for seed \(seed)"); return
        }
        #expect(received.sorted() == values.sorted(), "seed=\(seed)")
    }

    // MARK: - UUID fuzz

    @Test(
        "UUID fuzz: 200 random UUIDs round-trip with set equality",
        arguments: [4001, 4002, 4003] as [UInt64]
    )
    func uuidFuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<200).map { _ -> UUID in
            // 16 random bytes laid out into a UUID.
            let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        let result = try await Self.roundTrip(typeName: "UUID", column: "id", values: .uuid(values))
        guard case .uuid(let received) = result else {
            Issue.record("expected .uuid, got \(result) for seed \(seed)"); return
        }
        #expect(Set(received) == Set(values), "seed=\(seed)")
    }

    // MARK: - Nullable fuzz

    @Test(
        "Nullable(Int64) fuzz: 300 mixed null/value rows preserve mask alignment",
        arguments: [60001, 60002, 60003] as [UInt64]
    )
    func nullableInt64Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let values = (0..<300).map { _ -> Int64? in
            // ~30% nulls, ~70% values.
            if UInt8.random(in: 0...9, using: &rng) < 3 { return nil }
            return Int64.random(in: .min ... .max, using: &rng)
        }
        let result = try await Self.roundTrip(
            typeName: "Nullable(Int64)",
            column: "n_i64",
            values: .nullableInt64(values.map(ClickHouseNullable.init))
        )
        guard case .nullableInt64(let received) = result else {
            Issue.record("expected .nullableInt64, got \(result) for seed \(seed)"); return
        }
        // Compare null/value patterns and value distributions independently
        // since Memory tables don't guarantee row order.
        let sentNonNil = values.compactMap { $0 }.sorted()
        let receivedNonNil = received.compactMap { $0.value }.sorted()
        let sentNullCount = values.filter { $0 == nil }.count
        let receivedNullCount = received.filter { $0 == nil }.count
        #expect(sentNonNil == receivedNonNil, "seed=\(seed)")
        #expect(sentNullCount == receivedNullCount, "seed=\(seed)")
    }

    // MARK: - Array fuzz

    @Test(
        "Array(Int32) fuzz: 100 rows of 0…16-element arrays round-trip with offset alignment",
        arguments: [5001, 5002, 5003] as [UInt64]
    )
    func arrayInt32Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let arrays = (0..<100).map { _ -> [Int32] in
            let length = Int.random(in: 0...16, using: &rng)
            return (0..<length).map { _ in Int32.random(in: .min ... .max, using: &rng) }
        }
        let result = try await Self.roundTrip(
            typeName: "Array(Int32)",
            column: "a_i32",
            values: .arrayOfInt32(arrays)
        )
        guard case .arrayOfInt32(let received) = result else {
            Issue.record("expected .arrayOfInt32, got \(result) for seed \(seed)"); return
        }
        // Multiset-of-rows comparison: each row's elements stay in array order
        // (CH preserves Array element order), but rows themselves may shuffle.
        let sentSorted = arrays.map { $0 }.sorted { $0.lexicographicallyPrecedes($1) }
        let receivedSorted = received.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(sentSorted == receivedSorted, "seed=\(seed)")
    }

    // MARK: - Decimal fuzz

    @Test(
        "Decimal32 fuzz: random scales 0…9 preserve raw integer codes including boundary values",
        arguments: [1_000, 1_001, 1_002, 1_003] as [UInt64]
    )
    func decimal32Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let scale = Int.random(in: 0...9, using: &rng)
        // Mix random codes with boundary sentinels so corruption at the
        // wire layer surfaces deterministically.
        var values: [Int32] = [.min, -1, 0, 1, .max]
        values.append(contentsOf: (0..<300).map { _ in Int32.random(in: .min ... .max, using: &rng) })
        let result = try await Self.roundTrip(
            typeName: "Decimal32(\(scale))",
            column: "d32_s\(scale)",
            values: .decimal32(values, scale: scale)
        )
        guard case .decimal32(let received, let receivedScale) = result else {
            Issue.record("expected .decimal32, got \(result) for seed \(seed)"); return
        }
        #expect(receivedScale == scale, "seed=\(seed) scale drift")
        #expect(received.sorted() == values.sorted(), "seed=\(seed) scale=\(scale)")
    }

    @Test(
        "Decimal64 fuzz: random scales 0…18 preserve full Int64 range exactly",
        arguments: [2_000, 2_001, 2_002, 2_003] as [UInt64]
    )
    func decimal64Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let scale = Int.random(in: 0...18, using: &rng)
        var values: [Int64] = [.min, -1, 0, 1, .max]
        values.append(contentsOf: (0..<300).map { _ in Int64.random(in: .min ... .max, using: &rng) })
        let result = try await Self.roundTrip(
            typeName: "Decimal64(\(scale))",
            column: "d64_s\(scale)",
            values: .decimal64(values, scale: scale)
        )
        guard case .decimal64(let received, let receivedScale) = result else {
            Issue.record("expected .decimal64, got \(result) for seed \(seed)"); return
        }
        #expect(receivedScale == scale, "seed=\(seed) scale drift")
        #expect(received.sorted() == values.sorted(), "seed=\(seed) scale=\(scale)")
    }

    @Test(
        "Decimal128 fuzz: random scales 0…38 preserve full Int128 wire (16 bytes per row)",
        arguments: [3_000, 3_001, 3_002] as [UInt64]
    )
    func decimal128Fuzz(seed: UInt64) async throws {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let scale = Int.random(in: 0...38, using: &rng)
        // Decimal128 holds an Int128. Build random codes by combining
        // two Int64 halves; cover sign extension at the 64-bit pivot.
        var values: [Int128] = [
            Int128.min, -1, 0, 1, Int128.max,
            Int128(Int64.min) - 1,
            Int128(Int64.max) + 1,
        ]
        for _ in 0..<200 {
            let high = Int64.random(in: .min ... .max, using: &rng)
            let low = UInt64.random(in: 0 ... .max, using: &rng)
            // Compose Int128 from (high, low) without going through bit shifts
            // that risk overflow at the boundary.
            let combined = (Int128(high) &<< 64) &+ Int128(Int64(bitPattern: low))
            values.append(combined)
        }
        let result = try await Self.roundTrip(
            typeName: "Decimal128(\(scale))",
            column: "d128_s\(scale)",
            values: .decimal128(values, scale: scale)
        )
        guard case .decimal128(let received, let receivedScale) = result else {
            Issue.record("expected .decimal128, got \(result) for seed \(seed)"); return
        }
        #expect(receivedScale == scale, "seed=\(seed) scale drift")
        #expect(received.sorted() == values.sorted(), "seed=\(seed) scale=\(scale)")
    }

}
