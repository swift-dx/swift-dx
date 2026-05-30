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
import Testing

@Suite("ClickHouse bool column")
struct BoolColumnTests {

    @Test("bool column round-trips through encode and decode")
    func boolRoundTrip() throws {
        let column = ClickHouseBoolColumn(values: [true, false, true, true, false])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == column.rowCount)

        let decoded = try ClickHouseBoolColumn.decode(rows: column.rowCount, from: &buffer)
        #expect(decoded.values == column.values)
        #expect(decoded.spec == .bool)
    }

    @Test("registry dispatches bool spec to the bool column")
    func registryDispatchesBool() throws {
        let column = ClickHouseBoolColumn(values: [false, true])
        var buffer = ByteBuffer()
        column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .bool, rows: column.rowCount, from: &buffer)
        let typed = try #require(decoded as? ClickHouseBoolColumn)
        #expect(typed.values == column.values)
    }

    @Test("a non-zero, non-one byte surfaces a typed error")
    func invalidByteThrows() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(2))
        #expect(throws: ClickHouseError.self) {
            try ClickHouseBoolColumn.decode(rows: 2, from: &buffer)
        }
    }

    @Test("a 100 000-row Bool column round-trips byte-for-byte (covers bulk-write/read code path)")
    func largeRowCountRoundTripPreservesEveryByte() throws {
        // Pseudo-random pattern across 100k rows. A regression in the
        // bulk path (e.g., wrong stride or wrong decode validation)
        // would surface as a value mismatch.
        let count = 100_000
        var rng = SeededRandomNumberGenerator(seed: 0xB0_01_00_01_C0_DE_F0_0D)
        var values = [Bool]()
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(rng.next() & 1 == 0)
        }
        let column = ClickHouseBoolColumn(values: values)

        var buffer = ByteBuffer()
        column.encode(into: &buffer)
        #expect(buffer.readableBytes == count)

        let decoded = try ClickHouseBoolColumn.decode(rows: count, from: &buffer)
        #expect(decoded.values == values)
        #expect(buffer.readableBytes == 0, "decoder must consume the entire encoded payload")
    }

    @Test("a Bool column with a hostile non-0/non-1 byte at row 12345 surfaces invalidBoolean with the offending byte")
    func invalidByteInLargeColumnLocatedAndReported() {
        // Build a buffer of 12345 zeros + 1 invalid byte + 1 valid trailing zero,
        // then decode 12347 rows and assert the typed error type. The bulk
        // decoder must not silently accept a non-0/non-1 byte even in a
        // large column; the per-row validation has to remain in place.
        let prefixCount = 12_345
        var buffer = ByteBuffer()
        buffer.reserveCapacity(prefixCount + 2)
        buffer.writeBytes([UInt8](repeating: 0, count: prefixCount))
        buffer.writeInteger(UInt8(0xAA))
        buffer.writeInteger(UInt8(0))
        var thrown: Error?
        do {
            _ = try ClickHouseBoolColumn.decode(rows: prefixCount + 2, from: &buffer)
        } catch {
            thrown = error
        }
        #expect(thrown as? ClickHouseError == .invalidBoolean(rawValue: 0xAA))
    }

}
