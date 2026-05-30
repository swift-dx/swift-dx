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

// Pure value-level state machine for the CH protocol handshake. The
// connection layer drives this: it sends `openingBytes(...)` first,
// then feeds incoming socket bytes to `process(incoming:)` until the
// outcome is `.complete` (proceed to query phase), `.rejected` (auth
// or routing failure — close the connection), or it has yielded
// `.awaitMore` and waits for the next socket read.
//
// The negotiated revision returned in `.complete` is `min(client,
// server)` per CH's protocol convention; both sides use that revision
// for every subsequent packet's conditional fields.
struct ClickHouseHandshake: Sendable {

    enum Outcome: Sendable, Equatable {

        case complete(negotiatedRevision: UInt64, serverHello: ClickHouseServerHelloPacket)
        case rejected(ClickHouseServerExceptionPacket)
        case awaitMore

    }

    let clientRevision: UInt64

    static func openingBytes(clientHello: ClickHouseClientHelloPacket) throws -> ByteBuffer {
        var buffer = ByteBuffer()
        try ClickHouseClientPacketWriter.write(.hello(clientHello), into: &buffer, revision: clientHello.protocolRevision)
        return buffer
    }

    func process(incoming buffer: inout ByteBuffer) throws -> Outcome {
        let frame = try ClickHouseFraming.tryFrame(from: &buffer) { incoming in
            try ClickHouseServerPacketReader.read(from: &incoming, revision: clientRevision)
        }
        switch frame {
        case .needsMoreBytes:
            return .awaitMore
        case .complete(let packet):
            switch packet {
            case .hello(let serverHello):
                let negotiated = min(clientRevision, serverHello.serverRevision)
                return .complete(negotiatedRevision: negotiated, serverHello: serverHello)
            case .exception(let exception):
                return .rejected(exception)
            default:
                throw ClickHouseError.unexpectedHandshakeResponse(receivedPacketName: String(describing: Self.markerOf(packet)))
            }
        }
    }

    private static func markerOf(_ packet: ClickHouseServerPacket) -> ClickHouseServerPacketType {
        switch packet {
        case .hello: return .hello
        case .data: return .data
        case .exception: return .exception
        case .progress: return .progress
        case .pong: return .pong
        case .endOfStream: return .endOfStream
        case .profileInfo: return .profileInfo
        case .totals: return .totals
        case .extremes: return .extremes
        case .log: return .log
        case .tableColumns: return .tableColumns
        case .readTaskRequest: return .readTaskRequest
        case .profileEvents: return .profileEvents
        case .timezoneUpdate: return .timezoneUpdate
        }
    }

}
