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

// A value destined for a ClickHouse LowCardinality(String) or
// LowCardinality(FixedString(N)) column. The wrapper carries the row's
// own value as raw bytes (UTF-8 for a String inner, the fixed-width
// content for a FixedString inner) plus the inner-type discriminator; the
// encoder builds the per-block dictionary and index stream across all
// rows of the column.
public struct ClickHouseLowCardinality: Sendable, Hashable, Codable {

    public let inner: ClickHouseLowCardinalityInner
    public let value: [UInt8]

    public init(inner: ClickHouseLowCardinalityInner, value: [UInt8]) {
        self.inner = inner
        self.value = value
    }

    public init(_ string: String) {
        self.inner = .string
        self.value = Array(string.utf8)
    }

    public static func fixedString(_ bytes: [UInt8], length: Int) -> ClickHouseLowCardinality {
        ClickHouseLowCardinality(inner: .fixedString(length: length), value: bytes)
    }

    public var string: String {
        String(decoding: value, as: UTF8.self)
    }
}
