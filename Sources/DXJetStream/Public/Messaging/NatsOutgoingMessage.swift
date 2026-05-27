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

public struct NatsOutgoingMessage: Sendable {

    public let dedup: NatsMessageDedup
    public let headers: [NatsHeader]
    public let payload: [UInt8]

    public init(dedup: NatsMessageDedup = .noDedup, headers: [NatsHeader] = [], payload: [UInt8]) {
        self.dedup = dedup
        self.headers = headers
        self.payload = payload
    }
}

extension NatsOutgoingMessage {

    @inline(__always)
    var wireMessageId: String {
        switch dedup {
        case .noDedup: return ""
        case .dedupId(let id): return id
        }
    }
}
