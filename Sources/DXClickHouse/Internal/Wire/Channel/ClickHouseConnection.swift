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
import Synchronization

// A live ClickHouse TCP connection wrapping a NIO Channel that has
// the typed encoder/decoder + inbound stream handler installed. Once
// the handshake has completed (slice 9h's factory will do this) the
// channel exchanges typed packets, and this wrapper is the high-level
// API the query layer uses.
//
// `@unchecked Sendable` reflects the underlying invariant: NIO's
// Channel is event-loop-pinned and handles its own concurrency, so
// wrapping in an actor would only add hop overhead.
final class ClickHouseConnection: @unchecked Sendable {

    private let channel: Channel
    private let inboundHandler: ClickHouseInboundStreamHandler
    private let packetReader: ClickHousePacketReader
    private let closing = Mutex<Bool>(false)
    let metadata: ClickHouseConnectionMetadata
    let compression: ClickHouseCompressionMethod

    init(
        channel: Channel,
        inboundHandler: ClickHouseInboundStreamHandler,
        metadata: ClickHouseConnectionMetadata,
        compression: ClickHouseCompressionMethod = .uncompressed
    ) {
        self.channel = channel
        self.inboundHandler = inboundHandler
        self.packetReader = ClickHousePacketReader(stream: inboundHandler.packets)
        self.metadata = metadata
        self.compression = compression
    }

    // Pull the next inbound packet for this connection. Every
    // production query path goes through this single entry point so
    // there is exactly one AsyncIterator on `inboundHandler.packets`
    // for the connection's lifetime (see `ClickHousePacketReader`).
    // That eliminates the multi-iterator collision that trips Swift's
    // AsyncStream runtime check when cancellation interleaves two
    // query loops on the same connection.
    func nextPacket() async throws -> ClickHouseServerPacketReadOutcome {
        try await packetReader.next()
    }

    // Test-only accessor for the raw inbound packet stream. Unit tests
    // build their own iterators to inspect packet flow against an
    // EmbeddedChannel; that's safe because each test has its own
    // connection instance and stream. Production code MUST route
    // through `nextPacket()` to avoid creating multiple iterators on
    // the same shared stream.
    var inboundPackets: AsyncThrowingStream<ClickHouseServerPacket, Error> {
        inboundHandler.packets
    }

    var isActive: Bool {
        // Honour both the channel's own state AND the synchronous
        // "logically closed" flag. closeNonBlocking() schedules a NIO
        // close asynchronously, so channel.isActive can stay true
        // briefly after we've decided to tear the connection down.
        // Pool acquires that race the close window must see this flag
        // immediately so they don't hand a doomed connection to a new
        // caller (which would surface as "I/O on closed channel").
        guard !closing.withLock({ $0 }) else { return false }
        return channel.isActive
    }

    func send(_ packet: ClickHouseClientPacket) async throws {
        try await channel.writeAndFlush(packet).get()
    }

    func close() async throws {
        // Set the synchronous closing flag before awaiting the NIO
        // close future so any concurrent reader of `isActive` sees the
        // teardown immediately, even before channelInactive fires. The
        // flag is also set by closeNonBlocking() — calling both is
        // harmless because withLockedValue is a serialised set-true.
        closing.withLock { $0 = true }
        // Tolerate "already closed" — the SELECT/INSERT lifecycles
        // tear down the channel on certain error paths and the caller
        // may also call close() explicitly. The second call is a
        // no-op rather than a ChannelError.
        do {
            try await channel.close().get()
        } catch let error as ChannelError where error == .alreadyClosed {
            return
        }
    }

    // Fire-and-forget channel close usable from non-async contexts
    // (e.g. `withTaskCancellationHandler` onCancel callbacks). NIO
    // schedules the close on the channel's event loop; channelInactive
    // fires asynchronously after the socket is torn down. Idempotent —
    // a follow-up async `close()` is a no-op when the channel is
    // already closed.
    nonisolated func closeNonBlocking() {
        closing.withLock { $0 = true }
        channel.close(mode: .all, promise: nil)
    }

    // Best-effort safety net for a Connection that's dropped without
    // an explicit close(). The pool's `withConnection` always ensures
    // `release()` runs and `release()` discards inactive connections,
    // so production code shouldn't hit this path. But unit tests that
    // construct Connections directly against EmbeddedChannel — and any
    // caller that bypasses the pool — would otherwise leak the open
    // channel until the EventLoopGroup is torn down.
    //
    // Idempotent: if close already ran, the synchronous `closing` flag
    // is set and `closeNonBlocking()` is a no-op (NIO ignores
    // `.alreadyClosed`).
    deinit {
        if !closing.withLock({ $0 }) {
            channel.close(mode: .all, promise: nil)
        }
    }

}
