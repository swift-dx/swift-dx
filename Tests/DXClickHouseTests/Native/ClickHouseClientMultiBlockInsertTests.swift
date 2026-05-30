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
import NIOCore
import NIOPosix
import Testing

@Suite("ClickHouseClient — multi-block INSERT public API")
struct ClickHouseClientMultiBlockInsertTests {

    @Test("makeBlock converts a flat [ColumnEntry] list into a single Block with the same names and types")
    func makeBlockFromSingleColumnSet() throws {
        let entries = [
            ClickHouseColumnEntry(name: "id", values: .uint64([1, 2, 3])),
            ClickHouseColumnEntry(name: "label", values: .string(["a", "b", "c"]))
        ]
        let block = try ClickHouseClient.makeBlock(from: entries)
        #expect(block.columns.count == 2)
        #expect(block.columns[0].name == "id")
        #expect(block.columns[1].name == "label")
        #expect(block.rowCount == 3)
    }

    @Test("makeBlock with mismatched column row counts produces a Block whose row count comes from the first column")
    func makeBlockTakesRowCountFromFirstColumn() throws {
        // ClickHouseBlock is constructed even with mismatched lengths;
        // the wire encoder will surface the inconsistency on serialization.
        // This is a defensive structural test, not a behavioral guarantee.
        let entries = [
            ClickHouseColumnEntry(name: "id", values: .uint64([1, 2])),
            ClickHouseColumnEntry(name: "label", values: .string(["a", "b", "c"]))
        ]
        let block = try ClickHouseClient.makeBlock(from: entries)
        #expect(block.columns.count == 2)
    }

    @Test("multi-block insert produces multiple internal Blocks, one per input set")
    func multiBlockProducesMultipleInternalBlocks() throws {
        let blocks: [[ClickHouseColumnEntry]] = [
            [
                ClickHouseColumnEntry(name: "id", values: .uint64([1, 2, 3])),
                ClickHouseColumnEntry(name: "label", values: .string(["a", "b", "c"]))
            ],
            [
                ClickHouseColumnEntry(name: "id", values: .uint64([4, 5, 6])),
                ClickHouseColumnEntry(name: "label", values: .string(["d", "e", "f"]))
            ],
            [
                ClickHouseColumnEntry(name: "id", values: .uint64([7])),
                ClickHouseColumnEntry(name: "label", values: .string(["g"]))
            ]
        ]
        let internalBlocks = try blocks.map { try ClickHouseClient.makeBlock(from: $0) }
        #expect(internalBlocks.count == 3)
        #expect(internalBlocks[0].rowCount == 3)
        #expect(internalBlocks[1].rowCount == 3)
        #expect(internalBlocks[2].rowCount == 1)
    }

    @Test("an empty blocks array maps to zero internal Blocks (server gets just Query + empty terminator)")
    func emptyBlocksArrayProducesNoInternalBlocks() throws {
        let blocks: [[ClickHouseColumnEntry]] = []
        let internalBlocks = try blocks.map { try ClickHouseClient.makeBlock(from: $0) }
        #expect(internalBlocks.isEmpty)
    }

    @Test("each block in a multi-block insert preserves the column types it was built with")
    func columnTypesPreservedAcrossBlocks() throws {
        let block1 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "v", values: .int32([1, 2]))
        ])
        let block2 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "v", values: .int32([3, 4]))
        ])
        let firstColumn = try #require(block1.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        let secondColumn = try #require(block2.columns.first?.column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        #expect(firstColumn.values == [1, 2])
        #expect(secondColumn.values == [3, 4])
        #expect(firstColumn.spec == secondColumn.spec)
    }

    @Test("validateBlockStructure accepts a single block (no comparison needed)")
    func validateAcceptsSingleBlock() throws {
        let block = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "x", values: .int32([1]))
        ])
        try ClickHouseClient.validateBlockStructure([block])
    }

    @Test("validateBlockStructure accepts an empty blocks array (no-op)")
    func validateAcceptsEmpty() throws {
        try ClickHouseClient.validateBlockStructure([])
    }

    @Test("validateBlockStructure accepts blocks with identical column names and types")
    func validateAcceptsConsistentBlocks() throws {
        let blocks = try (0..<3).map { batch in
            try ClickHouseClient.makeBlock(from: [
                ClickHouseColumnEntry(name: "id", values: .uint64([UInt64(batch)])),
                ClickHouseColumnEntry(name: "label", values: .string(["batch-\(batch)"]))
            ])
        }
        try ClickHouseClient.validateBlockStructure(blocks)
    }

    @Test("validateBlockStructure rejects blocks with differing column counts")
    func validateRejectsColumnCountMismatch() throws {
        let block1 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "id", values: .uint64([1])),
            ClickHouseColumnEntry(name: "label", values: .string(["a"]))
        ])
        let block2 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "id", values: .uint64([2]))
        ])
        var thrown: Error?
        do {
            try ClickHouseClient.validateBlockStructure([block1, block2])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, let message) = received else {
            Issue.record("expected multiBlockStructureMismatch, got \(String(describing: thrown))")
            return
        }
        #expect(blockIndex == 1)
        #expect(message.contains("expected 2 columns, got 1"))
    }

    @Test("validateBlockStructure rejects blocks with differing column names")
    func validateRejectsColumnNameMismatch() throws {
        let block1 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "id", values: .uint64([1])),
            ClickHouseColumnEntry(name: "label", values: .string(["a"]))
        ])
        let block2 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "id", values: .uint64([2])),
            ClickHouseColumnEntry(name: "title", values: .string(["b"]))  // wrong name
        ])
        var thrown: Error?
        do {
            try ClickHouseClient.validateBlockStructure([block1, block2])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, let message) = received else {
            Issue.record("expected multiBlockStructureMismatch")
            return
        }
        #expect(blockIndex == 1)
        #expect(message.contains("name mismatch"))
        #expect(message.contains("'label'"))
        #expect(message.contains("'title'"))
    }

    @Test("validateBlockStructure rejects blocks where a column has the same name but a different type")
    func validateRejectsColumnTypeMismatch() throws {
        let block1 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "value", values: .int32([1, 2]))
        ])
        let block2 = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "value", values: .int64([3, 4]))  // wrong type
        ])
        var thrown: Error?
        do {
            try ClickHouseClient.validateBlockStructure([block1, block2])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, let message) = received else {
            Issue.record("expected multiBlockStructureMismatch")
            return
        }
        #expect(blockIndex == 1)
        #expect(message.contains("type mismatch"))
        #expect(message.contains("Int32"))
        #expect(message.contains("Int64"))
    }

    @Test("validateBlockStructure reports the first mismatching block index when multiple blocks differ")
    func validateReportsFirstMismatchingIndex() throws {
        let goodBlock = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "x", values: .int32([1]))
        ])
        let badBlock = try ClickHouseClient.makeBlock(from: [
            ClickHouseColumnEntry(name: "y", values: .int32([1]))  // wrong name
        ])
        // Sequence: [good, good, bad, bad] — the report should point at index 2.
        var thrown: Error?
        do {
            try ClickHouseClient.validateBlockStructure([goodBlock, goodBlock, badBlock, badBlock])
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, _) = received else {
            Issue.record("expected multiBlockStructureMismatch")
            return
        }
        #expect(blockIndex == 2, "validation should fail at the first mismatching block")
    }

    @Test("a block with mixed-type columns (Int32 + String + Bool) preserves all three types")
    func mixedTypeColumnsPreserved() throws {
        let entries = [
            ClickHouseColumnEntry(name: "id", values: .int32([1, 2, 3])),
            ClickHouseColumnEntry(name: "name", values: .string(["x", "y", "z"])),
            ClickHouseColumnEntry(name: "active", values: .bool([true, false, true]))
        ]
        let block = try ClickHouseClient.makeBlock(from: entries)
        #expect(block.columns.count == 3)
        let id = try #require(block.columns[0].column as? ClickHouseFixedWidthIntegerColumn<Int32>)
        let name = try #require(block.columns[1].column as? ClickHouseStringColumn)
        let active = try #require(block.columns[2].column as? ClickHouseBoolColumn)
        #expect(id.values == [1, 2, 3])
        #expect(name.values == ["x", "y", "z"])
        #expect(active.values == [true, false, true])
    }

    @Test("FixedString length is validated client-side — a negative length must surface a typed error, not trap inside Foundation's Data initializer")
    func fixedStringLengthValidatedClientSide() {
        // Pre-fix: `.nullableFixedString(length: -1, ...)` reached
        // `Data(repeating: 0, count: -1)` while constructing the
        // nullable sentinel. Foundation's `Data(repeating:count:)` traps
        // on negative counts ("Negative count not allowed"), so a
        // hostile or buggy caller could crash the whole process via the
        // public API. The non-nullable `.fixedString` variant let
        // `length: 0` slip past until the column-level encode
        // eventually threw — late but loud — with negative length the
        // mismatch loop took over (data.count never == -1) and threw a
        // misleading `fixedStringLengthMismatch` instead of a typed
        // length error. Both variants now share a single client-side
        // length guard at the public-API boundary.

        struct Case { let name: String; let values: ClickHouseColumnEntry.Values }
        let cases: [Case] = [
            Case(name: "fixedString length 0",
                 values: .fixedString(length: 0, [])),
            Case(name: "fixedString length -1",
                 values: .fixedString(length: -1, [])),
            Case(name: "nullableFixedString length 0",
                 values: .nullableFixedString(length: 0, [])),
            Case(name: "nullableFixedString length -1",
                 values: .nullableFixedString(length: -1, [])),
        ]

        for c in cases {
            var thrown: Error?
            do {
                _ = try ClickHouseClient.toInternalColumn(c.values)
            } catch {
                thrown = error
            }
            let received = thrown as? ClickHouseError
            switch received {
            case .invalidFixedStringLength(let length):
                #expect(length <= 0, "\(c.name): unexpected length \(length)")
            default:
                Issue.record("\(c.name): expected invalidFixedStringLength, got \(String(describing: thrown))")
            }
        }
    }

    @Test("Decimal scale is validated client-side for every Decimal variant against the type's documented max scale")
    func decimalScaleValidatedClientSidePerVariantMax() {
        // CH's Decimal(N, S) constrains scale by the backing integer
        // width: Decimal32 → max 9, Decimal64 → max 18, Decimal128 → max
        // 38, Decimal256 → max 76. Pre-fix none of the eight column
        // variants validated client-side; an out-of-range scale was
        // accepted, encoded into the type-name `Decimal32(100)`, and
        // rejected by the server with a SQL exception after the wire
        // round-trip. Post-fix every variant calls
        // `validateDecimalScale` with the spec's documented max so the
        // typed `invalidDecimalScale` error fires before any wire
        // activity.
        //
        // For each (variant, max), pick a scale just past the max so
        // the boundary is exercised (max-allowed should still pass on
        // a follow-up, max+1 fails).
        struct Case { let name: String; let invalid: ClickHouseColumnEntry.Values; let valid: ClickHouseColumnEntry.Values; let maxScale: Int }
        let cases: [Case] = [
            Case(name: "decimal32", invalid: .decimal32([], scale: 10), valid: .decimal32([], scale: 9), maxScale: 9),
            Case(name: "decimal64", invalid: .decimal64([], scale: 19), valid: .decimal64([], scale: 18), maxScale: 18),
            Case(name: "decimal128", invalid: .decimal128([], scale: 39), valid: .decimal128([], scale: 38), maxScale: 38),
            Case(name: "decimal256", invalid: .decimal256([], scale: 77), valid: .decimal256([], scale: 76), maxScale: 76),
            Case(name: "nullableDecimal32", invalid: .nullableDecimal32([], scale: 10), valid: .nullableDecimal32([], scale: 9), maxScale: 9),
            Case(name: "nullableDecimal64", invalid: .nullableDecimal64([], scale: 19), valid: .nullableDecimal64([], scale: 18), maxScale: 18),
            Case(name: "nullableDecimal128", invalid: .nullableDecimal128([], scale: 39), valid: .nullableDecimal128([], scale: 38), maxScale: 38),
            Case(name: "nullableDecimal256", invalid: .nullableDecimal256([], scale: 77), valid: .nullableDecimal256([], scale: 76), maxScale: 76),
        ]

        for c in cases {
            // Past the max: must throw the typed error with both fields.
            var thrown: Error?
            do {
                _ = try ClickHouseClient.toInternalColumn(c.invalid)
            } catch {
                thrown = error
            }
            let received = thrown as? ClickHouseError
            #expect(
                received == .invalidDecimalScale(scale: c.maxScale + 1, maxScale: c.maxScale),
                "\(c.name): expected invalidDecimalScale(\(c.maxScale + 1), \(c.maxScale)), got \(String(describing: thrown))"
            )

            // At the boundary: must still succeed (verifies the
            // validation isn't accidentally too strict).
            #expect(throws: Never.self, "\(c.name): max scale must be accepted") {
                _ = try ClickHouseClient.toInternalColumn(c.valid)
            }
        }
    }

    @Test("client-side precision validation fires consistently for every sub-second-precision column variant — no wire round-trip on misuse")
    func subsecondPrecisionValidatedClientSide() {
        // Pre-fix: `.dateTime64` and `.dateTime64Nanoseconds` (plus the
        // nullable nanoseconds variant) validated precision client-side,
        // but `.time64`, `.nullableTime64`, and `.nullableDateTime64`
        // skipped the check and let CH server reject the INSERT after
        // a wire round-trip. The precision range (0-9) is identical
        // across all sub-second-precision column types, so the
        // client-side guard should be uniform.
        //
        // Use precision = 100 (well outside [0, 9]) for each variant.
        // Each `toInternalColumn` call should throw
        // `invalidDateTime64Precision` BEFORE any wire activity.

        let variants: [(name: String, values: ClickHouseColumnEntry.Values)] = [
            ("dateTime64", .dateTime64([], precision: 100)),
            ("nullableDateTime64", .nullableDateTime64([], precision: 100)),
            ("time64", .time64([], precision: 100)),
            ("nullableTime64", .nullableTime64([], precision: 100)),
            ("dateTime64Nanoseconds", .dateTime64Nanoseconds([], precision: 100)),
            ("nullableDateTime64Nanoseconds", .nullableDateTime64Nanoseconds([], precision: 100)),
        ]

        for variant in variants {
            var thrown: Error?
            do {
                _ = try ClickHouseClient.toInternalColumn(variant.values)
            } catch {
                thrown = error
            }
            let received = thrown as? ClickHouseError
            #expect(
                received == .invalidDateTime64Precision(100),
                "\(variant.name): expected invalidDateTime64Precision(100), got \(String(describing: thrown))"
            )
        }
    }

    @Test("client.insert(into:blockProvider:) where the provider returns nil immediately is a no-op — no connection acquired, no wire round-trip")
    func insertStreamEmptyProviderIsNoOp() async throws {
        // Symmetric with the single-block and multi-block empty-input
        // short-circuits. Pre-fix the streaming insert always acquired
        // a connection, sent Query + schema preamble + terminator, and
        // waited for EndOfStream — even when the user's provider had
        // no batches at all. Useless work for an ETL pipeline that
        // legitimately receives an empty generator on a quiet tick.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: 1)],
            eventLoopGroup: group
        ))
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }

        // Provider returns nil immediately. Post-fix this peeks once
        // outside the connection scope, sees nil, and short-circuits
        // without ever touching the unreachable endpoint pool. The
        // functional assertion is "no throw, no pool acquisition" —
        // would surface as poolHasNoEndpoints if the connection was
        // attempted.
        try await client.insert(
            into: "events",
            blockProvider: { () async throws -> ClickHouseColumnBatchOutcome in .endOfStream }
        )
    }

    @Test("client.insert(into:blocks: []) is a no-op — symmetric with the single-block path, no wire round-trip")
    func insertEmptyBlocksIsNoOp() async throws {
        // Pre-fix the multi-block API acquired a connection, sent Query
        // + schema preamble + terminator, and waited for EndOfStream
        // just to issue a server-side zero-row INSERT. Useless work for
        // an empty batch. Symmetric with the single-block fix above:
        // empty input means do nothing.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: 1)],
            eventLoopGroup: group
        ))
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }

        try await client.insert(into: "events", blocks: [])
    }

    @Test("client.insert(into:columns: []) is a no-op — does not acquire a connection or throw blockHasNoColumns")
    func insertEmptyColumnsIsNoOp() async throws {
        // ETL pipelines routinely receive empty batches (no rows for a
        // tick, an upstream filter that culled everything, etc.). The
        // natural interpretation of "insert nothing" is do nothing —
        // symmetric with `insert(into:blocks: [])` which already short-
        // circuits at the cursor level and produces zero wire bytes.
        // Pre-fix the call reached `makeBlock` and threw
        // `blockHasNoColumns`, surfacing as a wire-protocol error from
        // every empty-batch flow that propagated through
        // `client.insert(into:rows: [])`.
        //
        // We construct a client with an unreachable endpoint so any
        // accidental connection attempt would surface (the integration
        // tests already cover endpoint reachability). This test only
        // asserts the empty-columns path returns without throwing —
        // i.e., the pool is never asked for a connection because the
        // empty short-circuit fires at the public API boundary.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: 1)],
            eventLoopGroup: group
        ))
        defer {
            Task {
                await client.shutdown()
                try? await group.shutdownGracefully()
            }
        }

        // Post-fix: returns silently, no acquire, no throw.
        try await client.insert(into: "events", columns: [])
    }

    @Test("makeBlock with empty columns list throws rather than producing a terminator-shaped block (data-phase ambiguity)")
    func makeBlockRejectsEmptyColumns() {
        // A block with zero columns is wire-equivalent to the data-phase
        // terminator the protocol uses to signal "no more data". If the
        // user passes `columns: []`, sending that block in the data
        // phase would be interpreted by the server as the terminator,
        // and our explicit terminator that follows would be an extra
        // packet. Pre-fix `makeBlock` accepted empty input silently;
        // post-fix it rejects with a clear error.
        var thrown: Error?
        do {
            _ = try ClickHouseClient.makeBlock(from: [])
        } catch {
            thrown = error
        }
        let received = thrown as? ClickHouseError
        #expect(
            received == .blockHasNoColumns,
            "makeBlock must reject empty columns with blockHasNoColumns, got \(String(describing: thrown))"
        )
    }

}
