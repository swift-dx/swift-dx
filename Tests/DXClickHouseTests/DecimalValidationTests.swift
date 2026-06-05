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

import DXClickHouse
import Foundation
import Testing

// ClickHouse Decimal columns require 1 <= precision <= 76 and scale <=
// precision. The encoder must reject out-of-range precision/scale at the
// boundary; otherwise the bad column type is shipped and the server fails
// the whole INSERT with an opaque error instead of a clear client one.
@Suite("Decimal encoder validates precision and scale")
struct DecimalValidationTests {

    struct Row: Codable, Sendable { let amount: ClickHouseDecimal }

    private enum Outcome: Sendable, Equatable {
        case encoded
        case rejected(stage: String)
        case otherError(String)
    }

    private static func encode(precision: UInt8, scale: UInt8) -> Outcome {
        let row = Row(amount: ClickHouseDecimal(unscaled: 1234, precision: precision, scale: scale))
        do {
            _ = try ClickHouseRowEncoder().encode([row])
            return .encoded
        } catch let error {
            if case .protocolError(let stage, _) = error { return .rejected(stage: stage) }
            return .otherError(String(describing: error))
        }
    }

    @Test("a valid Decimal precision and scale encodes")
    func validDecimalEncodes() {
        #expect(Self.encode(precision: 18, scale: 4) == .encoded)
    }

    @Test("precision above 76 is rejected")
    func precisionTooLargeRejected() {
        #expect(Self.encode(precision: 100, scale: 2) == .rejected(stage: "encoder.decimal"))
    }

    @Test("precision of zero is rejected")
    func precisionZeroRejected() {
        #expect(Self.encode(precision: 0, scale: 0) == .rejected(stage: "encoder.decimal"))
    }

    @Test("scale greater than precision is rejected")
    func scaleExceedsPrecisionRejected() {
        #expect(Self.encode(precision: 9, scale: 20) == .rejected(stage: "encoder.decimal"))
    }
}
