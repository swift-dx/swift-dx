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

package enum JSONParser {

    package static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSONValue {
        try parse(bytes, limits: .standard)
    }

    package static func parse(_ bytes: [UInt8], limits: JSONParseLimits) throws(JSONParseError) -> JSONValue {
        try requireWithinSizeLimit(bytes.count, limit: limits.maxByteLength)
        var reader = JSONReader(bytes: bytes, limits: limits)
        return try reader.parseDocument()
    }

    package static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        try parse(Array(text.utf8), limits: .standard)
    }

    package static func parse(_ text: String, limits: JSONParseLimits) throws(JSONParseError) -> JSONValue {
        try parse(Array(text.utf8), limits: limits)
    }

    private static func requireWithinSizeLimit(_ length: Int, limit: Int) throws(JSONParseError) {
        guard length <= limit else { throw .documentTooLarge(byteLength: length, limit: limit) }
    }
}
