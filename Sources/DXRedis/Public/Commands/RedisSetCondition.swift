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

public enum RedisSetCondition: Sendable, Hashable {

    case always
    case ifAbsent
    case ifPresent

    var arguments: [[UInt8]] {
        switch self {
        case .always: []
        case .ifAbsent: [Array("NX".utf8)]
        case .ifPresent: [Array("XX".utf8)]
        }
    }
}
