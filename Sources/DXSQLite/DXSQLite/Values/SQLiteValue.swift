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

public enum SQLiteValue: Sendable, Equatable {

    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])
}

extension SQLiteValue {

    public var type: ColumnType {
        switch self {
        case .null: .null
        case .integer: .integer
        case .real: .real
        case .text: .text
        case .blob: .blob
        }
    }
}

extension SQLiteValue {

    public func integer() throws(SQLiteError) -> Int64 {
        guard case .integer(let value) = self else {
            throw SQLiteError.valueTypeMismatch(expected: .integer, actual: type)
        }
        return value
    }

    public func double() throws(SQLiteError) -> Double {
        guard case .real(let value) = self else {
            throw SQLiteError.valueTypeMismatch(expected: .real, actual: type)
        }
        return value
    }

    public func text() throws(SQLiteError) -> String {
        guard case .text(let value) = self else {
            throw SQLiteError.valueTypeMismatch(expected: .text, actual: type)
        }
        return value
    }

    public func blob() throws(SQLiteError) -> [UInt8] {
        guard case .blob(let value) = self else {
            throw SQLiteError.valueTypeMismatch(expected: .blob, actual: type)
        }
        return value
    }

    public func boolean() throws(SQLiteError) -> Bool {
        try integer() != 0
    }
}
