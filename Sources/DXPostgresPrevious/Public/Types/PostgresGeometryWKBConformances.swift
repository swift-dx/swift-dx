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

extension PostgresGeometry: PostgresDecodable {

    public static func decode(from value: PostgresDecodingValue) throws(PostgresError) -> PostgresGeometry {
        switch value.format {
        case .text: return try PostgresWKBDecoding.decodeHex(value.text)
        case .binary: return try PostgresWKBDecoding.decode(value.bytes)
        }
    }
}

extension PostgresGeometry: PostgresEncodable {

    public func encodeToText() throws(PostgresError) -> PostgresCell {
        PostgresTextEncoding.text(try PostgresWKBEncoding.encodeHex(self))
    }
}
