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

public enum RedisExpiration: Sendable, Hashable {

    case persist
    case keepExisting
    case seconds(Int)
    case milliseconds(Int)

    var arguments: [[UInt8]] {
        switch self {
        case .persist: []
        case .keepExisting: [Array("KEEPTTL".utf8)]
        case .seconds(let value): [Array("EX".utf8), Array(String(value).utf8)]
        case .milliseconds(let value): [Array("PX".utf8), Array(String(value).utf8)]
        }
    }
}
