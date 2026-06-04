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
import NIOCore

// Shared binary-format decoders backing the PostgresDecodable conformances on the
// extended-protocol path, where results arrive in PostgreSQL's network binary
// layout. Fixed-width integers are big-endian; floating point is the IEEE 754 bit
// pattern; UUIDs are the raw 16 bytes; temporal types are offsets from the
// PostgreSQL epoch (2000-01-01 UTC). Each decoder validates its byte length and
// throws a typed decoding error on a mismatch.
enum PostgresBinaryDecoding {

    static let epochSecondsSince1970: Double = 946_684_800

    static func fixedWidth<Value: FixedWidthInteger>(_ value: PostgresDecodingValue, as type: Value.Type) throws(PostgresError) -> Value {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let result = buffer.readInteger(endianness: .big, as: Value.self), buffer.readableBytes == 0 else {
            throw PostgresError.typeDecodingFailed(type: "\(Value.self)", reason: "expected \(Value.bitWidth / 8) binary bytes, got \(value.bytes.count)")
        }
        return result
    }

    static func int(_ value: PostgresDecodingValue) throws(PostgresError) -> Int {
        switch value.bytes.count {
        case 8: return Int(try fixedWidth(value, as: Int64.self))
        case 4: return Int(try fixedWidth(value, as: Int32.self))
        default: return try narrowInt(value)
        }
    }

    private static func narrowInt(_ value: PostgresDecodingValue) throws(PostgresError) -> Int {
        switch value.bytes.count {
        case 2: return Int(try fixedWidth(value, as: Int16.self))
        case 1: return Int(try fixedWidth(value, as: Int8.self))
        default: throw PostgresError.typeDecodingFailed(type: "Int", reason: "unexpected integer width \(value.bytes.count)")
        }
    }

    static func double(_ value: PostgresDecodingValue) throws(PostgresError) -> Double {
        switch value.bytes.count {
        case 4: return Double(try float(value))
        default: return Double(bitPattern: try fixedWidth(value, as: UInt64.self))
        }
    }

    static func float(_ value: PostgresDecodingValue) throws(PostgresError) -> Float {
        Float(bitPattern: try fixedWidth(value, as: UInt32.self))
    }

    static func bool(_ value: PostgresDecodingValue) throws(PostgresError) -> Bool {
        guard value.bytes.count == 1 else {
            throw PostgresError.typeDecodingFailed(type: "Bool", reason: "expected 1 binary byte, got \(value.bytes.count)")
        }
        return value.bytes[0] != 0
    }

    static func uuid(_ value: PostgresDecodingValue) throws(PostgresError) -> UUID {
        let bytes = value.bytes
        guard bytes.count == 16 else {
            throw PostgresError.typeDecodingFailed(type: "UUID", reason: "expected 16 binary bytes, got \(bytes.count)")
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // `timestamp`/`timestamptz` are microseconds, and `date` is whole days, both
    // counted from the PostgreSQL epoch of 2000-01-01 UTC.
    static func temporal(_ value: PostgresDecodingValue) throws(PostgresError) -> Date {
        switch value.dataTypeObjectID {
        case 1082: return try date(value)
        case 1114, 1184: return try timestamp(value)
        default: throw PostgresError.typeDecodingFailed(type: "Date", reason: "type OID \(value.dataTypeObjectID) is not a supported temporal type")
        }
    }

    private static func timestamp(_ value: PostgresDecodingValue) throws(PostgresError) -> Date {
        let microseconds = try fixedWidth(value, as: Int64.self)
        return Date(timeIntervalSince1970: epochSecondsSince1970 + Double(microseconds) / 1_000_000)
    }

    private static func date(_ value: PostgresDecodingValue) throws(PostgresError) -> Date {
        let days = try fixedWidth(value, as: Int32.self)
        return Date(timeIntervalSince1970: epochSecondsSince1970 + Double(days) * 86_400)
    }

    static func numeric(_ value: PostgresDecodingValue) throws(PostgresError) -> Decimal {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let digitCount = buffer.readInteger(endianness: .big, as: Int16.self),
              let weight = buffer.readInteger(endianness: .big, as: Int16.self),
              let sign = buffer.readInteger(endianness: .big, as: UInt16.self),
              buffer.readInteger(endianness: .big, as: Int16.self) != nil else {
            throw PostgresError.typeDecodingFailed(type: "Decimal", reason: "truncated numeric header")
        }
        let digits = try readDigits(&buffer, count: Int(digitCount))
        return try composeNumeric(digits: digits, weight: Int(weight), sign: sign)
    }

    private static func readDigits(_ buffer: inout ByteBuffer, count: Int) throws(PostgresError) -> [Int16] {
        var digits: [Int16] = []
        digits.reserveCapacity(count)
        for _ in 0..<count {
            guard let digit = buffer.readInteger(endianness: .big, as: Int16.self) else {
                throw PostgresError.typeDecodingFailed(type: "Decimal", reason: "truncated numeric digit group")
            }
            digits.append(digit)
        }
        return digits
    }

    private static func composeNumeric(digits: [Int16], weight: Int, sign: UInt16) throws(PostgresError) -> Decimal {
        guard sign != 0xC000 else {
            throw PostgresError.typeDecodingFailed(type: "Decimal", reason: "value is NaN")
        }
        var magnitude = Decimal(0)
        for digit in digits {
            magnitude = magnitude * 10_000 + Decimal(Int(digit))
        }
        let scaled = applyDecimalScale(magnitude, base10Exponent: (weight - digits.count + 1) * 4)
        return signedDecimal(scaled, negative: sign == 0x4000)
    }

    private static func signedDecimal(_ value: Decimal, negative: Bool) -> Decimal {
        negative ? -value : value
    }

    private static func applyDecimalScale(_ value: Decimal, base10Exponent: Int) -> Decimal {
        guard base10Exponent != 0 else { return value }
        let magnitude = pow(Decimal(10), abs(base10Exponent))
        return base10Exponent > 0 ? value * magnitude : value / magnitude
    }

    // `numeric` (1700) and `money` (790) both decode to Decimal but use different
    // binary layouts: numeric is a base-10000 digit array, money is a single int64
    // in the locale's minor units (cents at the default two fractional digits).
    static func decimalBinary(_ value: PostgresDecodingValue) throws(PostgresError) -> Decimal {
        guard value.dataTypeObjectID == 790 else { return try numeric(value) }
        return try money(value)
    }

    private static func money(_ value: PostgresDecodingValue) throws(PostgresError) -> Decimal {
        Decimal(try fixedWidth(value, as: Int64.self)) / 100
    }

    static func time(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresTime {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let microseconds = buffer.readInteger(endianness: .big, as: Int64.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresTime", reason: "truncated time value")
        }
        let offset = buffer.readInteger(endianness: .big, as: Int32.self) ?? 0
        return PostgresTime(microsecondsSinceMidnight: microseconds, zoneOffsetSeconds: offset)
    }

    static func interval(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresInterval {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let microseconds = buffer.readInteger(endianness: .big, as: Int64.self),
              let days = buffer.readInteger(endianness: .big, as: Int32.self),
              let months = buffer.readInteger(endianness: .big, as: Int32.self) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInterval", reason: "truncated interval value")
        }
        return PostgresInterval(months: months, days: days, microseconds: microseconds)
    }

    static func inet(_ value: PostgresDecodingValue) throws(PostgresError) -> PostgresInet {
        var buffer = ByteBuffer(bytes: value.bytes)
        guard let family = buffer.readInteger(as: UInt8.self),
              let prefix = buffer.readInteger(as: UInt8.self),
              let cidrFlag = buffer.readInteger(as: UInt8.self),
              let length = buffer.readInteger(as: UInt8.self),
              let address = buffer.readBytes(length: Int(length)) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInet", reason: "truncated inet value")
        }
        return PostgresInet(isIPv6: family == 3, address: address, prefixLength: prefix, isCIDR: cidrFlag != 0)
    }
}
