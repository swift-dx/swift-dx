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

// A value destined for a String-compatible JSON column: the raw JSON
// text held as UTF-8 bytes and serialized exactly like a ClickHouse
// String (UVarInt byte length followed by the bytes). Use a field of
// this type on a Codable row when the column is declared `String` and
// carries JSON text, or for servers and paths where the JSON value
// serializes String-compatibly.
//
// The native binary serialization of ClickHouse's modern `JSON` /
// `Object` type (typed sub-paths, dynamic sub-columns, per-row binary
// structure) is a distinct wire format and is not produced by this
// wrapper; it is deferred the same way as Variant and Dynamic. This
// wrapper covers the tractable, String-compatible case only.
public struct ClickHouseJSON: Sendable, Hashable, Codable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    public var text: String {
        String(decoding: bytes, as: UTF8.self)
    }
}
