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

@Suite("ClickHouse fixed-string column")
struct FixedStringColumnTests {

    @Test("FixedString round-trips at the configured length")
    func roundTripAtLength() throws {
        let length = 8
        let values: [Data] = [
            Data(repeating: 0, count: length),
            Data((0..<length).map { UInt8($0) }),
            Data(repeating: 0xFF, count: length),
        ]
        let column = ClickHouseFixedStringColumn(spec: .fixedString(length: length), length: length, values: values)
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == values.count * length)

        let decoded = try ClickHouseFixedStringColumn.decode(
            spec: .fixedString(length: length),
            length: length,
            rows: values.count,
            from: &buffer
        )
        #expect(decoded.values == values)
        #expect(decoded.spec == .fixedString(length: length))
        #expect(decoded.length == length)
        #expect(buffer.readableBytes == 0)
    }

    @Test("encode rejects a row whose length does not match the column length")
    func mismatchedRowLengthRejected() {
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 4),
            length: 4,
            values: [Data([0x01, 0x02, 0x03])]
        )
        var buffer = ByteBuffer()
        #expect {
            try column.encode(into: &buffer)
        } throws: { error in
            guard case ClickHouseError.fixedStringLengthMismatch(let expected, let actual) = error else {
                return false
            }
            return expected == 4 && actual == 3
        }
    }

    @Test("decode rejects a non-positive declared length")
    func invalidDeclaredLengthRejected() {
        var buffer = ByteBuffer()
        #expect(throws: ClickHouseError.invalidFixedStringLength(0)) {
            try ClickHouseFixedStringColumn.decode(spec: .fixedString(length: 0), length: 0, rows: 1, from: &buffer)
        }
    }

    @Test("decode of zero rows consumes zero bytes")
    func zeroRowsIsNoOp() throws {
        var buffer = ByteBuffer()
        let decoded = try ClickHouseFixedStringColumn.decode(
            spec: .fixedString(length: 16),
            length: 16,
            rows: 0,
            from: &buffer
        )
        #expect(decoded.values.isEmpty)
        #expect(buffer.readableBytes == 0)
    }

    @Test("decode reports the total byte deficit on truncation")
    func truncationReportsTotalDeficit() {
        var buffer = ByteBuffer()
        buffer.writeBytes(Array(repeating: UInt8(0), count: 30))
        do {
            _ = try ClickHouseFixedStringColumn.decode(
                spec: .fixedString(length: 16),
                length: 16,
                rows: 2,
                from: &buffer
            )
            Issue.record("expected truncation error")
        } catch let ClickHouseError.truncatedBuffer(needed, available) {
            #expect(needed == 32)
            #expect(available == 30)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("registry decode of FixedString preserves the spec length")
    func registryFixedStringRoundTrip() throws {
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 4),
            length: 4,
            values: [Data([0x01, 0x02, 0x03, 0x04]), Data([0xAA, 0xBB, 0xCC, 0xDD])]
        )
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)

        let decoded = try ClickHouseColumnRegistry.decode(
            spec: .fixedString(length: 4),
            rows: column.rowCount,
            from: &buffer
        )
        let typed = try #require(decoded as? ClickHouseFixedStringColumn)
        #expect(typed.spec == .fixedString(length: 4))
        #expect(typed.length == 4)
        #expect(typed.values == column.values)
    }

    @Test("IPv6 spec dispatches to a 16-byte FixedString column with the IPv6 spec preserved")
    func ipv6SharesFixedStringWire() throws {
        let bytes = Data((0..<16).map { UInt8($0) })
        let column = ClickHouseFixedStringColumn(spec: .ipv6, length: 16, values: [bytes])
        var buffer = ByteBuffer()
        try column.encode(into: &buffer)
        #expect(buffer.readableBytes == 16)

        let decoded = try ClickHouseColumnRegistry.decode(spec: .ipv6, rows: 1, from: &buffer)
        let typed = try #require(decoded as? ClickHouseFixedStringColumn)
        #expect(typed.spec == .ipv6)
        #expect(typed.length == 16)
        #expect(typed.values == [bytes])
    }

    @Test("encode rejects a FixedString column with length=0 just like decode does (symmetry)")
    func encodeRejectsZeroLengthSymmetricToDecode() {
        // FixedString(0) is a degenerate type ClickHouse server-side
        // does not support; the decoder already throws
        // `invalidFixedStringLength(0)` for it. Pre-fix the encoder
        // would silently accept length=0 and emit zero bytes
        // regardless of row count, leaving the wire short and
        // misframing every column that follows. The encoder must
        // reject the same shape symmetrically.
        let column = ClickHouseFixedStringColumn(
            spec: .fixedString(length: 0),
            length: 0,
            values: [Data(), Data()]
        )
        var buffer = ByteBuffer()
        var thrown: Error?
        do {
            try column.encode(into: &buffer)
        } catch {
            thrown = error
        }
        #expect(thrown as? ClickHouseError == .invalidFixedStringLength(0))
    }

}
