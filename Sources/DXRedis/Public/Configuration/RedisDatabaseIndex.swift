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

public struct RedisDatabaseIndex: Sendable, Hashable {

    public static var zero: RedisDatabaseIndex {
        RedisDatabaseIndex(unchecked: 0)
    }

    public let value: Int

    public init(_ value: Int) throws(RedisError) {
        guard value >= 0 else {
            throw RedisError.invalidDatabaseIndex(value)
        }
        self.value = value
    }

    init(unchecked value: Int) {
        self.value = value
    }
}
