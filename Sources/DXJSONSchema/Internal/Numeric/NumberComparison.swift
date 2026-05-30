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

import DXCore

enum NumberOrder: Sendable, Equatable {

    case ascending
    case same
    case descending
}

enum NumberComparison {

    static func order(_ lhs: JSONNumber, _ rhs: JSONNumber) -> NumberOrder {
        if lhs.hasFractionOrExponent || rhs.hasFractionOrExponent {
            return orderDoubles(lhs.doubleValue, rhs.doubleValue)
        }
        return orderIntegers(lhs.integerValue, rhs.integerValue)
    }

    static func orderDoubles(_ lhs: Double, _ rhs: Double) -> NumberOrder {
        if lhs < rhs { return .ascending }
        if lhs > rhs { return .descending }
        return .same
    }

    static func orderIntegers(_ lhs: Int128, _ rhs: Int128) -> NumberOrder {
        if lhs < rhs { return .ascending }
        if lhs > rhs { return .descending }
        return .same
    }

    static func isMultiple(_ value: JSONNumber, of factor: JSONNumber) -> Bool {
        if bothIntegers(value, factor) { return integerMultiple(value.integerValue, factor.integerValue) }
        return doubleMultiple(value.doubleValue, factor.doubleValue)
    }

    static func bothIntegers(_ lhs: JSONNumber, _ rhs: JSONNumber) -> Bool {
        !lhs.hasFractionOrExponent && !rhs.hasFractionOrExponent
    }

    static func integerMultiple(_ value: Int128, _ factor: Int128) -> Bool {
        guard factor != 0 else { return false }
        return value % factor == 0
    }

    static func doubleMultiple(_ value: Double, _ factor: Double) -> Bool {
        guard factor != 0 else { return false }
        let quotient = value / factor
        return quotient.isFinite && quotient.rounded() == quotient
    }
}
