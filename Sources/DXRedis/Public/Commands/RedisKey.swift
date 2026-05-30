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

public struct RedisKey: Sendable, Hashable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ text: String) {
        self.bytes = Array(text.utf8)
    }
}

extension RedisKey: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension RedisKey: CustomStringConvertible {

    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }
}
