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

// Decoding a Decimal column reads its precision and scale out of the type
// name. Precision was already bounded, but the scale was narrowed to UInt8
// without a range check, so a malformed or oversized scale (`Decimal(18,
// 300)`) trapped on the UInt8 conversion and crashed the process while
// decoding a SELECT result. Both must surface a typed error instead.
@Suite("Decimal type-parameter parsing is range-checked")
struct DecimalParametersTests {

    private static func parse(_ typeName: String) throws -> (precision: UInt8, scale: UInt8) {
        try ClickHouseCodableDecoder.parseDecimalParameters(typeName: typeName)
    }

    @Test("a valid generic Decimal parses its precision and scale")
    func validGeneric() throws {
        let parameters = try Self.parse("Decimal(18, 4)")
        #expect(parameters.precision == 18)
        #expect(parameters.scale == 4)
    }

    @Test("the named Decimal aliases carry their fixed precision")
    func namedAliases() throws {
        #expect(try Self.parse("Decimal64(4)") == (18, 4))
        #expect(try Self.parse("Decimal256(20)") == (76, 20))
    }

    @Test("a scale exceeding the precision is rejected, not trapped")
    func scaleAbovePrecisionRejected() {
        var threw = false
        do {
            _ = try Self.parse("Decimal(18, 300)")
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("an out-of-range scale on a named alias is rejected, not trapped")
    func aliasScaleOutOfRangeRejected() {
        var threw = false
        do {
            _ = try Self.parse("Decimal64(300)")
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
