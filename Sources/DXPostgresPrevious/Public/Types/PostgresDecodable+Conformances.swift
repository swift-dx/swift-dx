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

import Foundation

extension String: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> String {
        PostgresTextDecoding.string(value)
    }
}

extension Decimal: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Decimal {
        switch value.format {
        case .text: return try PostgresTextDecoding.decimal(value)
        case .binary: return try PostgresBinaryDecoding.decimalBinary(value)
        }
    }
}

extension Date: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Date {
        switch value.format {
        case .text: return try PostgresTimestampText.parse(value.text)
        case .binary: return try PostgresBinaryDecoding.temporal(value)
        }
    }
}

extension Int: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Int {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Int.self)
        case .binary: return try PostgresBinaryDecoding.int(value)
        }
    }
}

extension Int16: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Int16 {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Int16.self)
        case .binary: return try PostgresBinaryDecoding.fixedWidth(value, as: Int16.self)
        }
    }
}

extension Int32: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Int32 {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Int32.self)
        case .binary: return try PostgresBinaryDecoding.fixedWidth(value, as: Int32.self)
        }
    }
}

extension Int64: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Int64 {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Int64.self)
        case .binary: return try PostgresBinaryDecoding.fixedWidth(value, as: Int64.self)
        }
    }
}

extension Double: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Double {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Double.self)
        case .binary: return try PostgresBinaryDecoding.double(value)
        }
    }
}

extension Float: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Float {
        switch value.format {
        case .text: return try PostgresTextDecoding.lossless(value, as: Float.self)
        case .binary: return try PostgresBinaryDecoding.float(value)
        }
    }
}

extension Bool: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> Bool {
        switch value.format {
        case .text: return try PostgresTextDecoding.boolean(value)
        case .binary: return try PostgresBinaryDecoding.bool(value)
        }
    }
}

extension UUID: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> UUID {
        switch value.format {
        case .text: return try PostgresTextDecoding.uuid(value)
        case .binary: return try PostgresBinaryDecoding.uuid(value)
        }
    }
}

extension Array: PostgresDecodable where Element == UInt8 {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> [UInt8] {
        switch value.format {
        case .text: return try PostgresTextDecoding.bytea(value)
        case .binary: return value.bytes
        }
    }
}
