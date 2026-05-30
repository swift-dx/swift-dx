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

import NIOCore

// A decoded RESP reply. String and bulk payloads are carried as `ByteBuffer`
// slices of the receive buffer rather than freshly allocated `[UInt8]`, so an
// array reply of N elements costs N shared-storage references rather than N
// allocations. Read the bytes with `bufferValue()` (zero-copy), or `bytesValue()`
// / `stringValue()` when an owned copy is wanted.
public enum RESPValue: Sendable, Hashable {

    case simpleString(ByteBuffer)
    case bulkString(ByteBuffer)
    case integer(Int64)
    case array([RESPValue])
    case arrayReply(RedisReplyArray)
    case null
    case error(prefix: String, message: String)
}
