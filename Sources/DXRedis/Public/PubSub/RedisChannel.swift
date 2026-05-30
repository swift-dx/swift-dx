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

public struct RedisChannel: Sendable, Hashable {

    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    var bytes: [UInt8] {
        Array(name.utf8)
    }
}

extension RedisChannel: ExpressibleByStringLiteral {

    public init(stringLiteral value: String) {
        self.name = value
    }
}

extension RedisChannel: CustomStringConvertible {

    public var description: String { name }
}
