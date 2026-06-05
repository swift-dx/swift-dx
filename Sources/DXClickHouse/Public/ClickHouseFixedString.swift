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

// A value destined for a ClickHouse FixedString(length) column. Use a
// field of this type on a Codable row instead of `String` when the
// column is a fixed-width byte slot. At encode time the content is
// right-padded with zero bytes to `length`; supplying more than `length`
// bytes is rejected with a typed error. On decode the full `length`
// bytes are returned, trailing zero padding included.
public struct ClickHouseFixedString: Sendable, Hashable, Codable {

    public let bytes: [UInt8]
    public let length: Int

    // A FixedString(N) slot is always N bytes on the wire, so a value shorter
    // than `length` is zero-padded to the full slot. This keeps `bytes` the
    // full padded slot regardless of how the value was constructed, so a
    // value built here compares equal to the same value decoded from a result
    // column. An over-length value is left as-is; the encoder rejects it at
    // the insert boundary rather than silently truncating.
    public init(bytes: [UInt8], length: Int) {
        if bytes.count < length {
            self.bytes = bytes + [UInt8](repeating: 0, count: length - bytes.count)
        } else {
            self.bytes = bytes
        }
        self.length = length
    }

    public init(_ string: String, length: Int) {
        self.init(bytes: Array(string.utf8), length: length)
    }

    // The stored content as text, with the trailing zero padding a
    // FixedString(N) column carries on the wire removed, decoded as UTF-8.
    // This is the value to read for a fixed-width identifier or code column.
    // Binary content that may legitimately end in zero bytes must be read
    // from `bytes` instead, which preserves the full padded slot.
    public var text: String {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0 {
            end -= 1
        }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}
