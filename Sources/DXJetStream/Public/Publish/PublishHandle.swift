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

public struct PublishHandle: Sendable {

    public let traceId: NatsTraceId

    let barrier: PendingBarrier
    let loSuffix: UInt64
    let connection: JetStreamClientImpl

    public func wait() async throws(JetStreamError) {
        await barrier.wait()
        connection.unregisterBarrier(loSuffix: loSuffix)
        connection.emitPublishBatchAcked(traceId: traceId)
    }
}
