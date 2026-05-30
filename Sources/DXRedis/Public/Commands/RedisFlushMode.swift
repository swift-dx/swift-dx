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

public enum RedisFlushMode: Sendable, Hashable {

    case synchronous
    case asynchronous

    var token: String {
        switch self {
        case .synchronous: "SYNC"
        case .asynchronous: "ASYNC"
        }
    }
}
