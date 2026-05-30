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

// Round-trip a Ping/Pong exchange to verify the connection is alive
// and the server is responsive. Useful for pool health checks (before
// returning a stale connection to a caller) and as a heartbeat after
// long idle periods.
//
// Must not be called while another query is in flight — the connection
// has a single inbound packet stream and would mis-frame responses.
// The pool's `withConnection` ensures only one in-flight operation
// per connection at a time.
extension ClickHouseConnection {

    func ping() async throws {
        // Wrap the await in a cancellation handler so a Task.cancel()
        // on the calling side closes the channel and unblocks
        // `nextPacket()`. Without this, a hung server can keep the
        // calling Task suspended indefinitely because NIO's bridge to
        // Swift Concurrency does not propagate Task cancellation into
        // the channel pipeline. Closing the channel fires
        // `channelInactive`, which finishes the inbound stream so
        // `nextPacket()` returns nil and the call surfaces
        // `unexpectedConnectionClose`. Identical pattern to the query
        // path's `runWithCancellationGuard`.
        //
        // The outer catch tears the channel down on any throw —
        // unexpectedPingResponse in particular leaves the channel
        // active but the inbound stream in a state where the consumed
        // non-Pong packet may be followed by more stale bytes. If the
        // pool's `release()` parks this connection back in idle (it
        // checks `connection.isActive` which is still true at that
        // point), the next caller's query would then read those stale
        // bytes as its own response — silent cross-query mismatch.
        // Symmetric with `execute`, `runSelectStream`, and the bug-28
        // fix on `insertBlockStream`.
        do {
            try await withTaskCancellationHandler {
                try await send(.ping)
                let packet: ClickHouseServerPacket
                switch try await nextPacket() {
                case .packet(let p): packet = p
                case .streamEnded: throw ClickHouseError.unexpectedConnectionClose
                }
                guard case .pong = packet else {
                    throw ClickHouseError.unexpectedPingResponse(receivedKind: Self.describe(packet))
                }
            } onCancel: { [self] in
                closeNonBlocking()
            }
        } catch {
            try? await close()
            throw error
        }
    }

    private static func describe(_ packet: ClickHouseServerPacket) -> String {
        switch packet {
        case .hello: return "hello"
        case .data: return "data"
        case .exception: return "exception"
        case .progress: return "progress"
        case .pong: return "pong"
        case .endOfStream: return "endOfStream"
        case .profileInfo: return "profileInfo"
        case .totals: return "totals"
        case .extremes: return "extremes"
        case .log: return "log"
        case .tableColumns: return "tableColumns"
        case .readTaskRequest: return "readTaskRequest"
        case .profileEvents: return "profileEvents"
        case .timezoneUpdate: return "timezoneUpdate"
        }
    }

}
