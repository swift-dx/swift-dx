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

// Identifies a single lock acquisition. The token must be unique per holder so
// release and extend can verify ownership before acting, which is what stops a
// holder whose lock already expired from deleting a lock another holder has since
// taken. `random()` produces a globally-unique token.
public struct RedisLockToken: Sendable, Hashable {

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    public static func random() -> RedisLockToken {
        RedisLockToken(UUID().uuidString)
    }
}
