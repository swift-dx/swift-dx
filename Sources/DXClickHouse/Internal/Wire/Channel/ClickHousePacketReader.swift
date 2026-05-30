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

import NIOConcurrencyHelpers

// Owns the single AsyncIterator on a connection's inbound packet
// stream. AsyncThrowingStream supports exactly one iteration; calling
// `makeAsyncIterator()` more than once on the same stream is undefined
// behavior and trips Swift's runtime check (`attempt to await next()
// on more than one task`) when cancellation interleaves two query
// loops on the same connection.
//
// Centralising the iterator behind a single entry point means every
// query path (execute, insertBlockStream, streamUntilTerminated, ping)
// pulls packets through one method, sequentially across the
// connection's whole lifetime. The pool's `withConnection` already
// guarantees one in-flight operation per connection at a time, so
// concurrent calls to `next()` are not expected from production code.
//
// `@unchecked Sendable` is justified by the lock: every access to
// `iterator` happens inside `lock.withLock`, so the non-Sendable
// AsyncIterator never crosses an isolation boundary unprotected.
final class ClickHousePacketReader: @unchecked Sendable {

    private let lock = NIOLock()
    private var iterator: AsyncThrowingStream<ClickHouseServerPacket, Error>.AsyncIterator

    init(stream: AsyncThrowingStream<ClickHouseServerPacket, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> ClickHouseServerPacketReadOutcome {
        // The lock guards the iterator's storage — but the await
        // itself happens unlocked, because the `local` iterator is a
        // value-typed shell over a shared backing buffer. The lock
        // serialises swap-out / swap-in so concurrent callers don't
        // collide on a single live next(); the pool guarantees only
        // one is ever in flight per connection.
        var local = lock.withLock { iterator }
        let result = try await local.next()
        lock.withLockVoid { iterator = local }
        if let packet = result {
            return .packet(packet)
        }
        return .streamEnded
    }

}

// Outcome of pulling the next packet from a connection's inbound
// stream. `streamEnded` corresponds to the underlying AsyncIterator
// returning end-of-stream (server hung up or the inbound handler
// finished the stream).
enum ClickHouseServerPacketReadOutcome: Sendable {

    case packet(ClickHouseServerPacket)
    case streamEnded

}
