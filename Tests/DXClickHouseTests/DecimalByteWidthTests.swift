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

// The Decimal column-skip width is selected from the declared precision.
// Parsing that precision must be bounded: a malformed or oversized type
// name otherwise overflows the running Int total (a crash) or wraps
// through UInt8 to the wrong byte width, desyncing the drained stream.
@Suite("decimalByteWidth precision parsing")
struct DecimalByteWidthTests {

    private static func width(_ typeName: String) throws -> Int {
        try ClickHouseConnection.decimalByteWidth(typeName: typeName)
    }

    @Test("precision selects the byte width")
    func validWidths() throws {
        #expect(try Self.width("Decimal(9, 2)") == 4)
        #expect(try Self.width("Decimal(18, 4)") == 8)
        #expect(try Self.width("Decimal(38, 10)") == 16)
        #expect(try Self.width("Decimal(76, 20)") == 32)
    }

    @Test("the named Decimal aliases still map to their fixed widths")
    func namedAliases() throws {
        #expect(try Self.width("Decimal64(4)") == 8)
        #expect(try Self.width("Decimal256(10)") == 32)
    }

    @Test("a precision above 76 is rejected rather than wrapping to a wrong width")
    func precisionTooLargeRejected() {
        var threw = false
        do {
            _ = try Self.width("Decimal(100, 2)")
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("a wildly oversized precision is rejected before it overflows the parse")
    func oversizedPrecisionRejected() {
        var threw = false
        do {
            _ = try Self.width("Decimal(99999999999999999999, 2)")
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
