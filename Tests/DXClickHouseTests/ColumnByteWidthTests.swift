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
import Testing

// The fixed-width column-skip calculator decides how many bytes to skip
// for a scalar column while draining a result. A FixedString width that
// cannot be parsed used to silently fall back to 0 bytes — skipping
// nothing and desyncing the rest of the block. It must now throw, like the
// typed decoder's FixedString parser it shares.
@Suite("columnByteWidth fixed-width skip calculator")
struct ColumnByteWidthTests {

    private static func width(_ typeName: String, rows: Int) throws -> Int {
        try ClickHouseConnection.columnByteWidth(typeName: typeName, rows: rows)
    }

    @Test("scalar widths are rows times the element size")
    func scalarWidths() throws {
        #expect(try Self.width("UInt8", rows: 3) == 3)
        #expect(try Self.width("Int32", rows: 3) == 12)
        #expect(try Self.width("UInt64", rows: 3) == 24)
        #expect(try Self.width("UUID", rows: 3) == 48)
        #expect(try Self.width("BFloat16", rows: 3) == 6)
    }

    @Test("FixedString(N) is rows times N")
    func fixedStringWidth() throws {
        #expect(try Self.width("FixedString(44)", rows: 2) == 88)
    }

    @Test("Decimal width is selected from the precision")
    func decimalWidth() throws {
        #expect(try Self.width("Decimal(18, 4)", rows: 2) == 16)
    }

    @Test("a FixedString with an unparseable width throws instead of skipping zero bytes")
    func malformedFixedStringThrows() {
        var threw = false
        do {
            _ = try Self.width("FixedString()", rows: 2)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("a row count whose width product overflows Int throws instead of trapping")
    func overflowingRowCountThrows() {
        // A hostile server can declare a huge row count in a skipped block;
        // rows times the element width would otherwise overflow and trap.
        var threw = false
        do {
            _ = try Self.width("UInt64", rows: Int.max)
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
