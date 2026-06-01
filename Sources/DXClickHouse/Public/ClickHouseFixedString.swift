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

    public init(bytes: [UInt8], length: Int) {
        self.bytes = bytes
        self.length = length
    }

    public init(_ string: String, length: Int) {
        self.bytes = Array(string.utf8)
        self.length = length
    }
}
