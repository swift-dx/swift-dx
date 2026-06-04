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

extension PostgresTime: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresTime {
        switch value.format {
        case .text: return try PostgresTimeText.parse(value.text)
        case .binary: return try PostgresBinaryDecoding.time(value)
        }
    }
}

extension PostgresTime: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresInterval: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresInterval {
        switch value.format {
        case .text: return try PostgresIntervalText.parse(value.text)
        case .binary: return try PostgresBinaryDecoding.interval(value)
        }
    }
}

extension PostgresInterval: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}

extension PostgresInet: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresInet {
        switch value.format {
        case .text: return try PostgresInetText.parse(value.text)
        case .binary: return try PostgresBinaryDecoding.inet(value)
        }
    }
}

extension PostgresInet: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(description)
    }
}
