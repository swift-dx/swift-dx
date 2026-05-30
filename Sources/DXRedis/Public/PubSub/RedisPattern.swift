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

// A glob-style channel pattern for PSUBSCRIBE: `news.*`, `user.?.events`,
// `cache.[ab]*`. Matched server-side against published channel names; the
// concrete channel that matched is delivered to the handler alongside the
// message.
public struct RedisPattern: Sendable, Hashable {

    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    var bytes: [UInt8] {
        Array(value.utf8)
    }
}

extension RedisPattern: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self.value = value
    }
}

extension RedisPattern: CustomStringConvertible {

    public var description: String { value }
}
