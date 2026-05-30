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

package struct JSONNumber: Sendable {

    package let form: Form

    package enum Form: Sendable, Equatable {

        case signedInteger(Int64)
        case unsignedInteger(UInt64)
        case decimal(Double)
    }

    package init(form: Form) {
        self.form = form
    }

    package var source: String {
        switch form {
        case .signedInteger(let value): "\(value)"
        case .unsignedInteger(let value): "\(value)"
        case .decimal(let value): "\(value)"
        }
    }

    package var isInteger: Bool {
        switch form {
        case .signedInteger: true
        case .unsignedInteger: true
        case .decimal(let value): value.isFinite && value.rounded(.towardZero) == value
        }
    }

    package var doubleValue: Double {
        switch form {
        case .signedInteger(let value): Double(value)
        case .unsignedInteger(let value): Double(value)
        case .decimal(let value): value
        }
    }

    package var integerValue: Int128 {
        switch form {
        case .signedInteger(let value): Int128(value)
        case .unsignedInteger(let value): Int128(value)
        case .decimal(let value): truncatedDecimal(value)
        }
    }

    private func truncatedDecimal(_ value: Double) -> Int128 {
        if let exact = Int128(exactly: value.rounded(.towardZero)) { return exact }
        return 0
    }

    package var hasFractionOrExponent: Bool {
        if case .decimal = form { return true }
        return false
    }
}

extension JSONNumber: Equatable {

    package static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        if lhs.hasFractionOrExponent || rhs.hasFractionOrExponent {
            return lhs.doubleValue == rhs.doubleValue
        }
        return lhs.integerValue == rhs.integerValue
    }
}

extension JSONNumber: Hashable {

    package func hash(into hasher: inout Hasher) {
        hasher.combine(doubleValue)
    }
}
