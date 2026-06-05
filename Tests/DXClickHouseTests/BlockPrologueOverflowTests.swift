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
import Testing

// The block prologue's column and row counts arrive as server-supplied
// UVarInts. Converting them to Int unchecked would trap — and crash the
// whole client — on a value that exceeds Int, which a corrupt or hostile
// server can send in a single field. The parser must reject such a count
// as malformed instead.
@Suite("block prologue rejects out-of-range counts instead of trapping")
struct BlockPrologueOverflowTests {

    private func parse(blockInfoTerminator: Bool, columnCount: UInt64, rowCount: UInt64) -> Bool {
        var bytes: [UInt8] = []
        if blockInfoTerminator {
            ClickHouseWire.writeUVarInt(0, into: &bytes)
        }
        ClickHouseWire.writeUVarInt(columnCount, into: &bytes)
        ClickHouseWire.writeUVarInt(rowCount, into: &bytes)
        var threw = false
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            do {
                _ = try ClickHouseBlockParser.parsePrologue(base: base, offset: 0, limit: buffer.count)
            } catch {
                threw = true
            }
        }
        return threw
    }

    @Test("a column count exceeding Int range is rejected as malformed, not a trap")
    func hugeColumnCountThrows() {
        #expect(parse(blockInfoTerminator: true, columnCount: UInt64.max, rowCount: 0))
    }

    @Test("a row count exceeding Int range is rejected as malformed, not a trap")
    func hugeRowCountThrows() {
        #expect(parse(blockInfoTerminator: true, columnCount: 1, rowCount: UInt64.max))
    }

    @Test("an in-range prologue still parses cleanly")
    func inRangePrologueParses() {
        #expect(!parse(blockInfoTerminator: true, columnCount: 3, rowCount: 100))
    }

    // A column count that fits in Int but is absurdly large still drives an
    // immediate reserveCapacity in the block reader, allocating gigabytes
    // and crashing the process before a single column header is read. The
    // parser must reject such a count up front.
    @Test("an in-Int but absurd column count is rejected before it can OOM")
    func absurdColumnCountThrows() {
        #expect(parse(blockInfoTerminator: true, columnCount: 2_000_000, rowCount: 0))
    }

    @Test("a generously wide but plausible column count still parses")
    func wideButPlausibleColumnCountParses() {
        #expect(!parse(blockInfoTerminator: true, columnCount: 10_000, rowCount: 0))
    }

    // A large row count is read incrementally and bounded by the stream, so
    // it stays legal — large result blocks are real.
    @Test("a large but in-Int row count remains legal")
    func largeRowCountParses() {
        #expect(!parse(blockInfoTerminator: true, columnCount: 4, rowCount: 5_000_000))
    }
}
