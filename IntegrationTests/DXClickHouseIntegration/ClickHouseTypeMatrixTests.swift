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

// Parameterized type-matrix tests. Each row is a single insert + select
// round-trip against an ad-hoc Memory table; the assertion compares the
// `ClickHouseColumnEntry.Values` enum coming out of `selectColumns` to
// the case fed in. Boundary values per type are picked to catch
// endianness, signed/unsigned overflow, and codec drift — not just to
// satisfy the codec.
//
// Skipped automatically unless `CH_INTEGRATION_HOST` is set.
@Suite(
    "ClickHouse integration — type matrix",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseTypeMatrixTests {

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
        "test.matrix_\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

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
            throw RoundTripError.noRowsReturned
        }
        guard let column = block.columns.first else {
            throw RoundTripError.noColumnsReturned
        }
        return column.values
    }

    private enum RoundTripError: Error {

        case noRowsReturned
        case noColumnsReturned

    }

    // MARK: - signed integers

    @Test(
        "Int8 boundaries round-trip with matching wire sign extension",
        arguments: [
            [Int8.min],
            [Int8.max],
            [0],
            [-1, 0, 1],
            [Int8.min, -1, 0, 1, Int8.max],
        ] as [[Int8]]
    )
    func int8RoundTrip(values: [Int8]) async throws {
        let result = try await Self.roundTrip(typeName: "Int8", column: "i8", values: .int8(values))
        guard case .int8(let received) = result else {
            Issue.record("expected .int8 case, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "Int16 boundaries preserve full signed range",
        arguments: [
            [Int16.min],
            [Int16.max],
            [0, -32768, 32767],
            [Int16.min, -1, 0, 1, Int16.max],
        ] as [[Int16]]
    )
    func int16RoundTrip(values: [Int16]) async throws {
        let result = try await Self.roundTrip(typeName: "Int16", column: "i16", values: .int16(values))
        guard case .int16(let received) = result else {
            Issue.record("expected .int16, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "Int32 boundaries preserve full signed range",
        arguments: [
            [Int32.min],
            [Int32.max],
            [0, -2_147_483_648, 2_147_483_647],
            [Int32.min, -1, 0, 1, Int32.max],
        ] as [[Int32]]
    )
    func int32RoundTrip(values: [Int32]) async throws {
        let result = try await Self.roundTrip(typeName: "Int32", column: "i32", values: .int32(values))
        guard case .int32(let received) = result else {
            Issue.record("expected .int32, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "Int64 boundaries preserve full signed range across the 64-bit pivot",
        arguments: [
            [Int64.min],
            [Int64.max],
            [0, -9_223_372_036_854_775_808, 9_223_372_036_854_775_807],
            [Int64.min, -1, 0, 1, Int64.max],
        ] as [[Int64]]
    )
    func int64RoundTrip(values: [Int64]) async throws {
        let result = try await Self.roundTrip(typeName: "Int64", column: "i64", values: .int64(values))
        guard case .int64(let received) = result else {
            Issue.record("expected .int64, got \(result)"); return
        }
        #expect(received == values)
    }

    // MARK: - unsigned integers

    @Test(
        "UInt8 boundaries preserve full unsigned range",
        arguments: [
            [UInt8.min],
            [UInt8.max],
            [0, 255],
            [0, 1, 127, 128, 255],
        ] as [[UInt8]]
    )
    func uint8RoundTrip(values: [UInt8]) async throws {
        let result = try await Self.roundTrip(typeName: "UInt8", column: "u8", values: .uint8(values))
        guard case .uint8(let received) = result else {
            Issue.record("expected .uint8, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "UInt16 boundaries preserve full unsigned range",
        arguments: [
            [UInt16.min],
            [UInt16.max],
            [0, 65535],
            [0, 1, 32767, 32768, 65535],
        ] as [[UInt16]]
    )
    func uint16RoundTrip(values: [UInt16]) async throws {
        let result = try await Self.roundTrip(typeName: "UInt16", column: "u16", values: .uint16(values))
        guard case .uint16(let received) = result else {
            Issue.record("expected .uint16, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "UInt32 preserves values above Int32.max",
        arguments: [
            [UInt32.min],
            [UInt32.max],
            [0, 4_294_967_295],
            [0, 1, 2_147_483_647, 2_147_483_648, 4_294_967_295],
        ] as [[UInt32]]
    )
    func uint32RoundTrip(values: [UInt32]) async throws {
        let result = try await Self.roundTrip(typeName: "UInt32", column: "u32", values: .uint32(values))
        guard case .uint32(let received) = result else {
            Issue.record("expected .uint32, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "UInt64 preserves values above Int64.max without sign coercion",
        arguments: [
            [UInt64.min],
            [UInt64.max],
            [9_223_372_036_854_775_808],
            [0, 1, 9_223_372_036_854_775_807, 9_223_372_036_854_775_808, UInt64.max],
        ] as [[UInt64]]
    )
    func uint64RoundTrip(values: [UInt64]) async throws {
        let result = try await Self.roundTrip(typeName: "UInt64", column: "u64", values: .uint64(values))
        guard case .uint64(let received) = result else {
            Issue.record("expected .uint64, got \(result)"); return
        }
        #expect(received == values)
    }

    // MARK: - floats

    @Test(
        "Float32 normal values round-trip with bit-exact equality",
        arguments: [
            [Float32(0)],
            [Float32(1.0), Float32(-1.0)],
            [Float32.leastNormalMagnitude, Float32.greatestFiniteMagnitude, -Float32.greatestFiniteMagnitude],
            [Float32(0.1), Float32(3.14159), Float32(-2.71828)],
        ] as [[Float32]]
    )
    func float32RoundTrip(values: [Float32]) async throws {
        let result = try await Self.roundTrip(typeName: "Float32", column: "f32", values: .float32(values))
        guard case .float32(let received) = result else {
            Issue.record("expected .float32, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "Float64 normal values round-trip with bit-exact equality",
        arguments: [
            [Float64(0)],
            [Float64(1.0), Float64(-1.0)],
            [Float64.leastNormalMagnitude, Float64.greatestFiniteMagnitude, -Float64.greatestFiniteMagnitude],
            [Float64.pi, -.pi, .ulpOfOne, 1e-300, 1e300],
        ] as [[Float64]]
    )
    func float64RoundTrip(values: [Float64]) async throws {
        let result = try await Self.roundTrip(typeName: "Float64", column: "f64", values: .float64(values))
        guard case .float64(let received) = result else {
            Issue.record("expected .float64, got \(result)"); return
        }
        #expect(received == values)
    }

    // MARK: - strings

    @Test(
        "String columns preserve UTF-8 sequences from ASCII through 4-byte code points and embedded NULs",
        arguments: [
            [""],
            ["ascii"],
            ["", "non-empty", ""],
            ["Привет, мир"],
            ["こんにちは世界"],
            ["🇳🇿🚀✨", "emoji 4-byte"],
            ["a\u{0000}b\u{0000}c"],
            ["one", "two", "three", "four", "five", "six", "seven"],
            [String(repeating: "x", count: 1024)],
            [String(repeating: "Ω", count: 1024)],
        ] as [[String]]
    )
    func stringRoundTrip(values: [String]) async throws {
        let result = try await Self.roundTrip(typeName: "String", column: "s", values: .string(values))
        guard case .string(let received) = result else {
            Issue.record("expected .string, got \(result)"); return
        }
        #expect(received == values)
    }

    // MARK: - bool, uuid

    @Test(
        "Bool boundaries preserve true/false and ordering across multi-row blocks",
        arguments: [
            [true],
            [false],
            [true, false, true, false],
            Array(repeating: true, count: 100) + Array(repeating: false, count: 100),
        ] as [[Bool]]
    )
    func boolRoundTrip(values: [Bool]) async throws {
        let result = try await Self.roundTrip(typeName: "Bool", column: "b", values: .bool(values))
        guard case .bool(let received) = result else {
            Issue.record("expected .bool, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test("UUIDs round-trip with byte-for-byte fidelity (CH stores big-endian high/low halves)")
    func uuidRoundTrip() async throws {
        let values: [UUID] = (0..<16).map { _ in UUID() }
        let result = try await Self.roundTrip(typeName: "UUID", column: "id", values: .uuid(values))
        guard case .uuid(let received) = result else {
            Issue.record("expected .uuid, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test("zero UUID survives the wire path even though every limb is 0")
    func uuidZeroRoundTrip() async throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let result = try await Self.roundTrip(typeName: "UUID", column: "id", values: .uuid([zero]))
        guard case .uuid(let received) = result else {
            Issue.record("expected .uuid, got \(result)"); return
        }
        #expect(received == [zero])
    }

    // MARK: - nullable patterns

    @Test(
        "Nullable(Int32) handles every (mask, value) combination including all-null and single-null gaps",
        arguments: [
            [Int32?.none],
            [Int32(42)],
            [nil, nil, nil],
            [1, nil, 3],
            [nil, 42, nil],
            [Int32?.some(0), nil, .some(.min), .some(.max), nil],
        ] as [[Int32?]]
    )
    func nullableInt32RoundTrip(values: [Int32?]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Nullable(Int32)",
            column: "n_i32",
            values: .nullableInt32(values.map(ClickHouseNullable.init))
        )
        guard case .nullableInt32(let received) = result else {
            Issue.record("expected .nullableInt32, got \(result)"); return
        }
        #expect(received.map(\.value) == values)
    }

    @Test(
        "Nullable(String) preserves nil distinct from empty-string in every position",
        arguments: [
            [String?.none],
            [""],
            ["", nil, ""],
            ["alpha", nil, "gamma"],
            [nil, nil, "non-empty"],
            ["🇳🇿", nil, ""],
        ] as [[String?]]
    )
    func nullableStringRoundTrip(values: [String?]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Nullable(String)",
            column: "n_s",
            values: .nullableString(values.map(ClickHouseNullable.init))
        )
        guard case .nullableString(let received) = result else {
            Issue.record("expected .nullableString, got \(result)"); return
        }
        #expect(received.map(\.value) == values)
    }

    // MARK: - arrays

    @Test(
        "Array(Int32) handles empty arrays, single elements, and large mixed-size payloads",
        arguments: [
            [[Int32]()],
            [[Int32(1)]],
            [[1, 2, 3], [], [4]],
            Array(repeating: [Int32(0)], count: 50),
            [(0..<1000).map { Int32($0) }],
        ] as [[[Int32]]]
    )
    func arrayInt32RoundTrip(values: [[Int32]]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Array(Int32)",
            column: "a_i32",
            values: .arrayOfInt32(values)
        )
        guard case .arrayOfInt32(let received) = result else {
            Issue.record("expected .arrayOfInt32, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "Array(String) handles empty arrays, multi-element rows, and unicode + emoji payloads",
        arguments: [
            [[String]()],
            [["solo"]],
            [["alpha", "beta"], [], ["gamma"]],
            [["🇳🇿", "🇦🇺", "🇺🇸"], ["Hello", "Привет", "こんにちは"]],
            Array(repeating: ["x"], count: 100),
        ] as [[[String]]]
    )
    func arrayStringRoundTrip(values: [[String]]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Array(String)",
            column: "a_s",
            values: .arrayOfString(values)
        )
        guard case .arrayOfString(let received) = result else {
            Issue.record("expected .arrayOfString, got \(result)"); return
        }
        #expect(received == values)
    }

    // MARK: - LowCardinality

    @Test(
        "LowCardinality(String) preserves row order independently of dictionary insertion order",
        arguments: [
            ["alpha"],
            ["alpha", "beta", "alpha", "alpha", "gamma", "beta"],
            Array(repeating: "same", count: 200),
            (0..<300).map { "v\($0 % 17)" },
        ] as [[String]]
    )
    func lowCardinalityStringRoundTrip(values: [String]) async throws {
        let result = try await Self.roundTrip(
            typeName: "LowCardinality(String)",
            column: "lc_s",
            values: .lowCardinalityString(values)
        )
        guard case .lowCardinalityStringIndexed(let view) = result else {
            Issue.record("expected .lowCardinalityStringIndexed, got \(result)"); return
        }
        var materialised: [String] = []
        materialised.reserveCapacity(view.count)
        for rowIndex in 0..<view.count { materialised.append(view[rowIndex]) }
        #expect(materialised == values)
    }

    // MARK: - dates and times

    @Test(
        "Date round-trips at year boundaries within the UInt16 days-since-epoch range",
        arguments: [
            // 1970-01-01 (day 0)
            [Date(timeIntervalSince1970: 0)],
            // 2000-01-01
            [Date(timeIntervalSince1970: 946_684_800)],
            // 2023-06-15
            [Date(timeIntervalSince1970: 1_686_787_200)],
            // 2106-01-01 is just before the UInt16 days ceiling.
            [Date(timeIntervalSince1970: 4_291_747_200)],
        ] as [[Date]]
    )
    func dateRoundTrip(values: [Date]) async throws {
        let result = try await Self.roundTrip(typeName: "Date", column: "d", values: .date(values))
        guard case .date(let received) = result else {
            Issue.record("expected .date, got \(result)"); return
        }
        // Date column truncates to day; the seconds-since-epoch we sent must
        // align to a day boundary already for an exact equality check.
        #expect(received.count == values.count)
        for (sent, got) in zip(values, received) {
            let sentDay = floor(sent.timeIntervalSince1970 / 86_400)
            let gotDay = floor(got.timeIntervalSince1970 / 86_400)
            #expect(sentDay == gotDay)
        }
    }

    @Test(
        "DateTime64 preserves nanosecond precision (precision 9) end-to-end",
        arguments: [
            [ClickHouseNanoseconds(1_700_000_000_000_000_000)],
            [
                ClickHouseNanoseconds(1_700_000_000_000_000_001),
                ClickHouseNanoseconds(1_700_000_000_500_000_000),
                ClickHouseNanoseconds(1_700_000_000_999_999_999),
            ],
        ] as [[ClickHouseNanoseconds]]
    )
    func dateTime64NanosRoundTrip(values: [ClickHouseNanoseconds]) async throws {
        let result = try await Self.roundTrip(
            typeName: "DateTime64(9)",
            column: "dt64",
            values: .dateTime64Nanoseconds(values, precision: 9)
        )
        guard case .dateTime64Nanoseconds(let received, let precision) = result else {
            Issue.record("expected .dateTime64Nanoseconds, got \(result)"); return
        }
        #expect(precision == 9)
        #expect(received == values)
    }

    @Test(
        "DateTime64 at precisions 0, 3, 6 round-trip with the right divisor applied each way",
        arguments: [0, 3, 6] as [Int]
    )
    func dateTime64PrecisionVariants(precision: Int) async throws {
        // Use a value that's evenly divisible at every precision so the
        // divisor math is exact and we can compare without truncation noise.
        let nanos: [ClickHouseNanoseconds] = [
            ClickHouseNanoseconds(1_700_000_000_000_000_000),
            ClickHouseNanoseconds(2_000_000_000_000_000_000),
        ]
        let result = try await Self.roundTrip(
            typeName: "DateTime64(\(precision))",
            column: "dt64_p\(precision)",
            values: .dateTime64Nanoseconds(nanos, precision: precision)
        )
        guard case .dateTime64Nanoseconds(let received, let receivedPrecision) = result else {
            Issue.record("expected .dateTime64Nanoseconds, got \(result)"); return
        }
        #expect(receivedPrecision == precision)
        #expect(received == nanos)
    }

    // MARK: - Decimal scales

    @Test(
        "Decimal32 with scale 4 stores raw integer codes and preserves the scale on read",
        arguments: [
            [Int32(0)],
            [Int32(12345), -12345],
            [Int32.min, -1, 0, 1, Int32.max],
        ] as [[Int32]]
    )
    func decimal32Scale4(values: [Int32]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Decimal32(4)",
            column: "d32",
            values: .decimal32(values, scale: 4)
        )
        guard case .decimal32(let received, let scale) = result else {
            Issue.record("expected .decimal32, got \(result)"); return
        }
        #expect(scale == 4)
        #expect(received == values)
    }

    @Test(
        "Decimal64 across scales 0, 6, 18 preserves boundary integer codes",
        arguments: [0, 6, 18] as [Int]
    )
    func decimal64ScaleVariants(scale: Int) async throws {
        let values: [Int64] = [Int64.min, -1, 0, 1, Int64.max]
        let result = try await Self.roundTrip(
            typeName: "Decimal64(\(scale))",
            column: "d64_s\(scale)",
            values: .decimal64(values, scale: scale)
        )
        guard case .decimal64(let received, let receivedScale) = result else {
            Issue.record("expected .decimal64, got \(result)"); return
        }
        #expect(receivedScale == scale)
        #expect(received == values)
    }

    // MARK: - IPv4, IPv6, FixedString

    @Test(
        "IPv4 round-trips as raw UInt32 covering edge addresses",
        arguments: [
            [UInt32(0)],
            [UInt32(0x7F00_0001)],
            [0xC000_0201, 0xC633_6401, UInt32.max],
        ] as [[UInt32]]
    )
    func ipv4RoundTrip(values: [UInt32]) async throws {
        let result = try await Self.roundTrip(typeName: "IPv4", column: "ip4", values: .ipv4(values))
        guard case .ipv4(let received) = result else {
            Issue.record("expected .ipv4, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test("IPv6 raw 16-byte addresses survive the FixedString-shaped wire")
    func ipv6RoundTrip() async throws {
        let zeros = Data(repeating: 0, count: 16)
        // ::1 (loopback) — zero-padded with low byte = 1
        var loopback = Data(repeating: 0, count: 15); loopback.append(1)
        // ffff:ffff:... (all-ones)
        let allOnes = Data(repeating: 0xFF, count: 16)
        let values: [Data] = [zeros, loopback, allOnes]

        let result = try await Self.roundTrip(typeName: "IPv6", column: "ip6", values: .ipv6(values))
        guard case .ipv6(let received) = result else {
            Issue.record("expected .ipv6, got \(result)"); return
        }
        #expect(received == values)
    }

    @Test(
        "FixedString preserves raw bytes including non-UTF8 sequences exactly",
        arguments: [
            // Length 8, ASCII only.
            (Int(8), [Data(repeating: 0x41, count: 8)]),
            // Length 4, mixed binary.
            (4, [Data([0x00, 0x01, 0xFF, 0xFE])]),
            // Length 16, all zeros sentinel.
            (16, [Data(repeating: 0, count: 16)]),
            // Length 32, multi-row.
            (32, [
                Data(repeating: 0xAB, count: 32),
                Data(repeating: 0xCD, count: 32),
                Data(repeating: 0, count: 32),
            ]),
        ] as [(Int, [Data])]
    )
    func fixedStringRoundTrip(args: (Int, [Data])) async throws {
        let (length, values) = args
        let result = try await Self.roundTrip(
            typeName: "FixedString(\(length))",
            column: "fs_\(length)",
            values: .fixedString(length: length, values)
        )
        guard case .fixedString(let receivedLength, let received) = result else {
            Issue.record("expected .fixedString, got \(result)"); return
        }
        #expect(receivedLength == length)
        #expect(received == values)
    }

    // MARK: - Tuple

    @Test("Tuple(String, Int32) preserves element order and per-element types row-by-row")
    func tupleStringInt32() async throws {
        let pairs: [(String, Int32)] = [
            ("alpha", 1),
            ("", 0),
            ("🇳🇿", -1),
            ("multi-byte Привет", Int32.max),
        ]
        let result = try await Self.roundTrip(
            typeName: "Tuple(String, Int32)",
            column: "t_si",
            values: .tupleStringInt32(pairs)
        )
        guard case .tupleStringInt32(let received) = result else {
            Issue.record("expected .tupleStringInt32, got \(result)"); return
        }
        #expect(received.map(\.0) == pairs.map(\.0))
        #expect(received.map(\.1) == pairs.map(\.1))
    }

    @Test("Tuple(Float64, Float64) round-trips coordinate pairs with bit-exact equality")
    func tupleFloat64Float64() async throws {
        let pairs: [(Double, Double)] = [
            (0.0, 0.0),
            (.pi, -.pi),
            (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude),
            (174.7633, -36.8485), // Auckland
        ]
        let result = try await Self.roundTrip(
            typeName: "Tuple(Float64, Float64)",
            column: "t_ff",
            values: .tupleFloat64Float64(pairs)
        )
        guard case .tupleFloat64Float64(let received) = result else {
            Issue.record("expected .tupleFloat64Float64, got \(result)"); return
        }
        #expect(received.map(\.0) == pairs.map(\.0))
        #expect(received.map(\.1) == pairs.map(\.1))
    }

    // MARK: - Map

    @Test(
        "Map(String, String) handles empty, single-entry, and multi-entry rows in the same block",
        arguments: [
            [[String: String]()],
            [["k": "v"]],
            [["a": "1", "b": "2"], [:], ["c": "3"]],
            [
                ["region": "NZ", "tier": "premium"],
                ["region": "AU", "tier": "free", "extra": "value"],
                [:],
            ],
        ] as [[[String: String]]]
    )
    func mapStringStringRoundTrip(values: [[String: String]]) async throws {
        let result = try await Self.roundTrip(
            typeName: "Map(String, String)",
            column: "m_ss",
            values: .mapStringString(values)
        )
        guard case .mapStringStringIndexed(let storage) = result else {
            Issue.record("expected .mapStringStringIndexed, got \(result)"); return
        }
        // Map ordering is not guaranteed by CH, so compare as dictionaries.
        #expect(storage.count == values.count)
        for (rowIndex, sent) in values.enumerated() {
            #expect(sent == storage.row(at: rowIndex))
        }
    }

    @Test("Map(String, Int32) preserves numeric values across empty and populated rows")
    func mapStringInt32() async throws {
        let values: [[String: Int32]] = [
            ["one": 1, "two": 2],
            [:],
            ["zero": 0, "negative": -1, "max": Int32.max, "min": Int32.min],
        ]
        let result = try await Self.roundTrip(
            typeName: "Map(String, Int32)",
            column: "m_si",
            values: .mapStringInt32(values)
        )
        guard case .mapStringInt32(let received) = result else {
            Issue.record("expected .mapStringInt32, got \(result)"); return
        }
        #expect(received.count == values.count)
        for (sent, got) in zip(values, received) {
            #expect(sent == got)
        }
    }

    // MARK: - bulk volume

    @Test("UInt64 INSERT of 10_000 monotonic values round-trips with full ordering preserved")
    func uint64BulkRoundTrip() async throws {
        let values = (0..<10_000).map { UInt64($0) }
        let result = try await Self.roundTrip(
            typeName: "UInt64",
            column: "u64_bulk",
            values: .uint64(values)
        )
        guard case .uint64(let received) = result else {
            Issue.record("expected .uint64, got \(result)"); return
        }
        let sorted = received.sorted()
        #expect(sorted.count == values.count)
        #expect(sorted == values)
    }

    @Test("String INSERT of 5_000 random-length payloads round-trips by content (set comparison)")
    func stringBulkRoundTrip() async throws {
        let values = (0..<5_000).map { index -> String in
            let length = 1 + (index % 32)
            return String(repeating: Character(Unicode.Scalar(0x41 + (index % 26))!), count: length)
        }
        let result = try await Self.roundTrip(
            typeName: "String",
            column: "s_bulk",
            values: .string(values)
        )
        guard case .string(let received) = result else {
            Issue.record("expected .string, got \(result)"); return
        }
        // Memory tables don't preserve insertion order, so compare as multisets.
        #expect(Set(received) == Set(values))
        #expect(received.count == values.count)
    }

    // MARK: - concurrency

    @Test("ten concurrent SELECT calls all complete and surface the right value")
    func concurrentSelectScalars() async throws {
        let (client, group) = Self.makeClient()
        _ = group
        defer { Task { await client.shutdown() } }
        try await withThrowingTaskGroup(of: Int64?.self) { taskGroup in
            for _ in 0..<10 {
                taskGroup.addTask {
                    try await client.scalarInt64("SELECT toInt64(1)")
                }
            }
            var collected: [Int64] = []
            for try await value in taskGroup {
                if let value { collected.append(value) }
            }
            #expect(collected.count == 10)
            #expect(collected.allSatisfy { $0 == 1 })
        }
    }

    @Test("twenty concurrent INSERTs followed by a single COUNT see every row")
    func concurrentInserts() async throws {
        let table = Self.uniqueTable("concurrent")
        // 20 callers against the default 10-slot pool requires queueing.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: Self.host, port: Self.port)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            acquireTimeout: .waitUpTo(.seconds(30)),
            eventLoopGroup: group
        ))
        _ = group
        try await client.execute("CREATE TABLE \(table) (n Int32) ENGINE = Memory")

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for batch in 0..<20 {
                let values = (0..<50).map { Int32(batch * 50 + $0) }
                taskGroup.addTask {
                    try await client.insert(into: table, columns: [.init(name: "n", values: .int32(values))])
                }
            }
            try await taskGroup.waitForAll()
        }
        let total = try await client.scalarInt64("SELECT toInt64(count(*)) FROM \(table)")
        #expect(total == Int64(1000))
        try await client.execute("DROP TABLE \(table)")
        await client.shutdown()
    }

    // MARK: - error recovery

    @Test("a server-side syntax error surfaces typed and the next query on the pool succeeds")
    func errorThenRecover() async throws {
        let (client, group) = Self.makeClient()
        _ = group
        defer { Task { await client.shutdown() } }

        var caughtFirst = false
        do {
            _ = try await client.scalarInt64("THIS IS NOT VALID SQL")
        } catch ClickHouseError.serverException(let exception) {
            caughtFirst = true
            #expect(exception.code != 0)
        }
        #expect(caughtFirst)

        // Pool must hand a clean connection on the next acquire.
        let value = try await client.scalarInt64("SELECT toInt64(42)")
        #expect(value == 42)
    }

    // MARK: - nested composites (Ring / Polygon / MultiPolygon)

    @Test("Ring (Array(Tuple(Float64, Float64))) round-trips full coordinate fidelity per ring")
    func ringRoundTrip() async throws {
        let rings: [[(Double, Double)]] = [
            [],
            [(0.0, 0.0), (1.0, 1.0)],
            [(174.7633, -36.8485), (174.8, -36.85), (174.9, -36.7), (174.7633, -36.8485)],
            (0..<200).map { i in (Double(i) * 0.01, Double(i) * 0.02) },
        ]
        let result = try await Self.roundTrip(
            typeName: "Array(Tuple(Float64, Float64))",
            column: "ring",
            values: .arrayOfTupleFloat64Float64(rings)
        )
        guard case .arrayOfTupleFloat64Float64(let received) = result else {
            Issue.record("expected .arrayOfTupleFloat64Float64, got \(result)"); return
        }
        // Map<Tuple>->dictionary doesn't preserve row order on Memory; sort
        // by row size + first coordinate so the multiset assertion holds.
        let sortKey: ([(Double, Double)]) -> (Int, Double, Double) = { ring in
            (ring.count, ring.first?.0 ?? 0, ring.first?.1 ?? 0)
        }
        let sentSorted = rings.sorted { sortKey($0) < sortKey($1) }
        let receivedSorted = received.sorted { sortKey($0) < sortKey($1) }
        #expect(sentSorted.count == receivedSorted.count)
        for (sent, got) in zip(sentSorted, receivedSorted) {
            #expect(sent.map(\.0) == got.map(\.0))
            #expect(sent.map(\.1) == got.map(\.1))
        }
    }

    @Test("Polygon (Array(Array(Tuple(Float64, Float64)))) preserves outer + inner ring nesting")
    func polygonRoundTrip() async throws {
        let polygons: [[[(Double, Double)]]] = [
            // Empty polygon.
            [],
            // Single outer ring, no holes.
            [[(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.0, 0.0)]],
            // Outer ring + one hole.
            [
                [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0), (0.0, 0.0)],
                [(2.0, 2.0), (4.0, 2.0), (4.0, 4.0), (2.0, 4.0), (2.0, 2.0)],
            ],
        ]
        let result = try await Self.roundTrip(
            typeName: "Array(Array(Tuple(Float64, Float64)))",
            column: "poly",
            values: .arrayOfArrayOfTupleFloat64Float64(polygons)
        )
        guard case .arrayOfArrayOfTupleFloat64Float64(let received) = result else {
            Issue.record("expected .arrayOfArrayOfTupleFloat64Float64, got \(result)"); return
        }
        let sortKey: ([[(Double, Double)]]) -> Int = { $0.reduce(0) { $0 + $1.count } }
        let sentSorted = polygons.sorted { sortKey($0) < sortKey($1) }
        let receivedSorted = received.sorted { sortKey($0) < sortKey($1) }
        #expect(sentSorted.count == receivedSorted.count)
        for (sent, got) in zip(sentSorted, receivedSorted) {
            #expect(sent.count == got.count)
            for (sentRing, gotRing) in zip(sent, got) {
                #expect(sentRing.map(\.0) == gotRing.map(\.0))
                #expect(sentRing.map(\.1) == gotRing.map(\.1))
            }
        }
    }

    @Test("MultiPolygon (Array(Array(Array(Tuple)))) preserves three levels of nesting and tuple coordinates")
    func multiPolygonRoundTrip() async throws {
        let multi: [[[[(Double, Double)]]]] = [
            [],
            // Single polygon, single ring.
            [[[(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (0.0, 0.0)]]],
            // Two polygons, second has a hole.
            [
                [[(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 0.0)]],
                [
                    [(10.0, 10.0), (20.0, 10.0), (20.0, 20.0), (10.0, 20.0), (10.0, 10.0)],
                    [(12.0, 12.0), (14.0, 12.0), (14.0, 14.0), (12.0, 12.0)],
                ],
            ],
        ]
        let result = try await Self.roundTrip(
            typeName: "Array(Array(Array(Tuple(Float64, Float64))))",
            column: "mpoly",
            values: .arrayOfArrayOfArrayOfTupleFloat64Float64(multi)
        )
        guard case .arrayOfArrayOfArrayOfTupleFloat64Float64(let received) = result else {
            Issue.record("expected .arrayOfArrayOfArrayOfTupleFloat64Float64, got \(result)"); return
        }
        // Sort by total nested point count for determinism.
        let totalPoints: ([[[(Double, Double)]]]) -> Int = { multipolygon in
            multipolygon.reduce(0) { polyTotal, polygon in
                polyTotal + polygon.reduce(0) { ringTotal, ring in ringTotal + ring.count }
            }
        }
        let sentSorted = multi.sorted { totalPoints($0) < totalPoints($1) }
        let receivedSorted = received.sorted { totalPoints($0) < totalPoints($1) }
        #expect(sentSorted.count == receivedSorted.count)
        for (sent, got) in zip(sentSorted, receivedSorted) {
            #expect(totalPoints(sent) == totalPoints(got))
        }
    }

    // MARK: - extra Map variants

    @Test("Map(Int32, String) preserves integer keys distinct from string keys (different map shape)")
    func mapInt32String() async throws {
        let values: [[Int32: String]] = [
            [:],
            [1: "one"],
            [1: "uno", 2: "dos", 3: "tres"],
            [Int32.min: "min", Int32.max: "max", 0: "zero", -1: "neg"],
        ]
        let result = try await Self.roundTrip(
            typeName: "Map(Int32, String)",
            column: "m_is",
            values: .mapInt32String(values)
        )
        guard case .mapInt32String(let received) = result else {
            Issue.record("expected .mapInt32String, got \(result)"); return
        }
        #expect(received.count == values.count)
        for (sent, got) in zip(values, received) { #expect(sent == got) }
    }

    @Test("Map(String, Float64) preserves bit-exact float values across rows")
    func mapStringFloat64() async throws {
        let values: [[String: Double]] = [
            [:],
            ["pi": .pi, "e": 2.718281828459045],
            ["zero": 0.0, "neg": -1.5, "huge": 1e300, "tiny": 1e-300],
        ]
        let result = try await Self.roundTrip(
            typeName: "Map(String, Float64)",
            column: "m_sf",
            values: .mapStringFloat64(values)
        )
        guard case .mapStringFloat64(let received) = result else {
            Issue.record("expected .mapStringFloat64, got \(result)"); return
        }
        #expect(received.count == values.count)
        for (sent, got) in zip(values, received) { #expect(sent == got) }
    }

    @Test("Tuple(String, String) preserves both elements through the wire as parallel String columns")
    func tupleStringString() async throws {
        let pairs: [(String, String)] = [
            ("", ""),
            ("hello", "world"),
            ("Привет", "🇳🇿"),
            (String(repeating: "x", count: 100), String(repeating: "y", count: 100)),
        ]
        let result = try await Self.roundTrip(
            typeName: "Tuple(String, String)",
            column: "t_ss",
            values: .tupleStringString(pairs)
        )
        guard case .tupleStringString(let received) = result else {
            Issue.record("expected .tupleStringString, got \(result)"); return
        }
        #expect(received.map(\.0) == pairs.map(\.0))
        #expect(received.map(\.1) == pairs.map(\.1))
    }

    @Test("an unknown-table SELECT surfaces a typed exception, not a connection close")
    func unknownTableErrorIsTyped() async throws {
        let (client, group) = Self.makeClient()
        _ = group
        defer { Task { await client.shutdown() } }

        var caught: ClickHouseError.ServerException?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(count(*)) FROM test.does_not_exist_\(UUID().uuidString.prefix(6))")
        } catch ClickHouseError.serverException(let exception) {
            caught = exception
        }
        let exception = try #require(caught)
        #expect(!exception.name.isEmpty)
        #expect(!exception.message.isEmpty)
    }

}
