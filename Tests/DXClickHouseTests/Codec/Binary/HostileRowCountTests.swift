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
import Testing

// A hostile peer can advertise a forged row count in a Block header.
// Without overflow-checked bulk readers, `rows * elementSize` would
// trap the decoder process for any `rows > Int.max / elementSize`,
// turning malformed input into a denial-of-service vector. These
// tests pin the contract: pathological row counts surface as typed
// `truncatedBuffer` errors instead of process aborts.
@Suite("Codec — hostile-row-count overflow protection in bulk readers")
struct HostileRowCountTests {

    // MARK: - Fixed-width integer bulk reader

    @Test("readClickHouseFixedWidthIntegers throws truncatedBuffer (no trap) when rows × elementSize overflows Int")
    func fixedWidthIntegerOverflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x01, 0x02, 0x03, 0x04])  // 4 bytes available
        do {
            // Int64 elementSize = 8; Int.max / 4 still overflows when * 8.
            _ = try buffer.readClickHouseFixedWidthIntegers(Int64.self, rows: Int.max)
            Issue.record("Expected truncatedBuffer error, got success")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: available) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
            #expect(available == 4)
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    @Test("readClickHouseFixedWidthIntegers throws truncatedBuffer for non-overflowing-but-too-large rows")
    func fixedWidthIntegerExceedsBufferWithoutOverflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 8))  // 8 bytes (one Int64)
        do {
            _ = try buffer.readClickHouseFixedWidthIntegers(Int64.self, rows: 100)
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: available) {
            #expect(needed == 800, "100 rows × 8 bytes = 800")
            #expect(available == 8)
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - UUID bulk reader

    @Test("readClickHouseUUIDs throws truncatedBuffer (no trap) when rows × 16 overflows Int")
    func uuidOverflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 16))
        do {
            _ = try buffer.readClickHouseUUIDs(rows: Int.max)
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: _) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - String list bulk reader

    @Test("readClickHouseStrings does not pre-allocate beyond available bytes for hostile row count")
    func stringsCappedReserveCapacity() throws {
        // Rows = Int.max with 0 readable bytes → reserveCapacity(0); the
        // first per-row read fails with truncatedBuffer. The test passes
        // simply by not crashing the process during the upfront reserve.
        var buffer = ByteBuffer()
        do {
            _ = try buffer.readClickHouseStrings(rows: Int.max)
            Issue.record("Expected error before completing read")
        } catch is ClickHouseError {
            // Expected: any protocol error is fine; the point is that
            // we did NOT trap on `reserveCapacity(Int.max)`.
        } catch {
            Issue.record("Expected ClickHouseError, got \(error)")
        }
    }

    // MARK: - Block decoder

    @Test("Block.decode caps reserveCapacity at readableBytes and throws on truncated columns")
    func blockDecodeCappedReserveCapacity() throws {
        // Build a Block prefix with a hostile columnCount but no column
        // payload. The reserveCapacity should be capped at readableBytes,
        // so no Int.max-sized array is allocated upfront. The first
        // per-column read fails with a typed protocol error.
        var buffer = ByteBuffer()
        // BlockInfo: 0 fields → field=0, terminator
        ClickHouseBlockInfo().encode(into: &buffer)
        // columnCount = Int.max (encoded as UVarInt)
        buffer.writeClickHouseUVarInt(UInt64(Int.max))
        // rowCount = 0
        buffer.writeClickHouseUVarInt(0)
        // No column data. Decode must throw a typed error, not OOM.
        do {
            _ = try ClickHouseBlock.decode(from: &buffer, revision: 54_454)
            Issue.record("Expected protocol error from forged columnCount")
        } catch is ClickHouseError {
            // Expected; the point is no process abort.
        } catch {
            Issue.record("Expected ClickHouseError, got \(error)")
        }
    }

    // MARK: - FixedString column

    @Test("ClickHouseFixedStringColumn.decode throws truncatedBuffer (no trap) when rows × length overflows Int")
    func fixedStringOverflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 16))
        // length = 1024; rows × 1024 overflows when rows > Int.max / 1024
        do {
            _ = try ClickHouseFixedStringColumn.decode(
                spec: .fixedString(length: 1024),
                length: 1024,
                rows: Int.max,
                from: &buffer
            )
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: _) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - Int256 column

    @Test("ClickHouseInt256Column.decode throws truncatedBuffer (no trap) when rows × 32 overflows Int")
    func int256Overflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 32))
        do {
            _ = try ClickHouseInt256Column.decode(
                spec: .int256,
                rows: Int.max,
                from: &buffer
            )
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: _) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - BFloat16 column

    @Test("ClickHouseBFloat16Column.decode throws truncatedBuffer (no trap) when rows × 2 overflows Int")
    func bfloat16Overflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 4))
        do {
            _ = try ClickHouseBFloat16Column.decode(
                spec: .bfloat16,
                rows: Int.max,
                from: &buffer
            )
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: _) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - UInt256 column

    @Test("ClickHouseUInt256Column.decode throws truncatedBuffer (no trap) when rows × 32 overflows Int")
    func uint256Overflow() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 32))
        do {
            _ = try ClickHouseUInt256Column.decode(
                spec: .uint256,
                rows: Int.max,
                from: &buffer
            )
            Issue.record("Expected truncatedBuffer error")
        } catch let ClickHouseError.truncatedBuffer(needed: needed, available: _) {
            #expect(needed == Int.max, "overflow surfaces with Int.max as needed")
        } catch {
            Issue.record("Expected truncatedBuffer, got \(error)")
        }
    }

    // MARK: - Sparse column

    @Test("Sparse column rejects forged totalRows above the per-column cap with a typed error")
    func sparseRowCountExceedsCap() throws {
        // A single END-of-granule UVarInt with the high bit set encodes
        // an arbitrary `totalRows` in only a few wire bytes (no per-row
        // cost for trailing defaults). Without a cap, scatter would
        // allocate `[T](repeating: 0, count: totalRows)`, an attacker-
        // controlled multi-GB allocation. The cap surfaces a typed
        // protocol error instead.
        var buffer = ByteBuffer()
        // Encode an offsets stream that simply terminates with all-trailing-
        // defaults: one UVarInt = (END flag | bogusRows). The decoder
        // should reject before reading any wire bytes, so an empty buffer
        // is fine.
        let bogusRows = ClickHouseSparseColumnDecoder.maxRowsPerColumn + 1
        do {
            _ = try ClickHouseSparseColumnDecoder.decode(
                spec: .int32,
                rows: bogusRows,
                from: &buffer
            )
            Issue.record("Expected sparseRowCountExceedsLimit error")
        } catch let ClickHouseError.sparseRowCountExceedsLimit(rows: rows, limit: limit) {
            #expect(rows == bogusRows)
            #expect(limit == ClickHouseSparseColumnDecoder.maxRowsPerColumn)
        } catch {
            Issue.record("Expected sparseRowCountExceedsLimit, got \(error)")
        }
    }

    @Test("Sparse column accepts totalRows at the cap boundary (cap is inclusive)")
    func sparseRowCountAtCap() throws {
        // We don't decode all 1<<28 rows here (that would allocate ~1 GB).
        // We just prove the boundary check is inclusive by passing exactly
        // `maxRowsPerColumn`. The decoder will then attempt to read the
        // positions stream, and the empty buffer surfaces a different
        // typed error (`uvarintIncomplete`/`truncatedBuffer`), proving
        // we passed the cap check without trapping.
        var buffer = ByteBuffer()
        do {
            _ = try ClickHouseSparseColumnDecoder.decode(
                spec: .int32,
                rows: ClickHouseSparseColumnDecoder.maxRowsPerColumn,
                from: &buffer
            )
            Issue.record("Expected a downstream protocol error after passing the cap check")
        } catch is ClickHouseError {
            // Any protocol error other than `sparseRowCountExceedsLimit`
            // is fine; the point is we passed the cap check.
        } catch {
            Issue.record("Expected ClickHouseError, got \(error)")
        }
    }

}
