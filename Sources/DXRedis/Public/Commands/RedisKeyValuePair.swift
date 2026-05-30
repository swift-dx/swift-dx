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

public struct RedisKeyValuePair: Sendable, Hashable {

    public let key: RedisKey
    public let value: [UInt8]

    public init(key: RedisKey, value: [UInt8]) {
        self.key = key
        self.value = value
    }

    public init(key: RedisKey, value: String) {
        self.key = key
        self.value = Array(value.utf8)
    }
}
