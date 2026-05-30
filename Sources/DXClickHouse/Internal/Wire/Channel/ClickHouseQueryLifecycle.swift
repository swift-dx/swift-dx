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

// Pure value-level translator from server packets received during a
// query phase into typed lifecycle events. Centralizes the protocol-
// level "which packets are valid during a query?" decision so the
// orchestrator (slice 11) only deals with semantic events, not raw
// packet variants.
//
// Stateless today; the type exists as a struct rather than a free
// function because INSERT semantics will need a phase distinction
// (sending input vs receiving output) and we want the public API
// shape to stay stable across that addition.
struct ClickHouseQueryLifecycle: Sendable {

    enum Event: Sendable {

        case data(ClickHouseBlock)
        case totals(ClickHouseBlock)
        case extremes(ClickHouseBlock)
        case log(ClickHouseBlock)
        case progress(ClickHouseServerProgressPacket)
        case profileInfo(ClickHouseServerProfileInfoPacket)
        case profileEvents(ClickHouseBlock)
        case tableColumns(ClickHouseServerTableColumnsPacket)
        case completed
        case failed(ClickHouseServerExceptionPacket)
        case ignored

    }

    let revision: UInt64

    func handle(_ packet: ClickHouseServerPacket) throws -> Event {
        switch packet {
        case .data(_, let block): return .data(block)
        case .totals(_, let block): return .totals(block)
        case .extremes(_, let block): return .extremes(block)
        case .log(_, let block): return .log(block)
        case .progress(let progress): return .progress(progress)
        case .profileInfo(let profilePacket): return .profileInfo(profilePacket)
        case .profileEvents(_, let block): return .profileEvents(block)
        case .tableColumns(let cols): return .tableColumns(cols)
        case .endOfStream: return .completed
        case .exception(let exception): return .failed(exception)
        case .hello:
            throw ClickHouseError.unexpectedPacketDuringQuery(receivedPacketName: "hello")
        case .pong:
            throw ClickHouseError.unexpectedPacketDuringQuery(receivedPacketName: "pong")
        case .readTaskRequest:
            throw ClickHouseError.unexpectedPacketDuringQuery(receivedPacketName: "readTaskRequest")
        case .timezoneUpdate:
            // Server's session timezone update; informational, lifecycle continues.
            return .ignored
        }
    }

}
