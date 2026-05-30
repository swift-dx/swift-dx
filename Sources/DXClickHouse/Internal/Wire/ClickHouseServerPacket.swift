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

// Tagged union of every server-to-client packet variant we decode.
// The marker (UVarInt) precedes the body on the wire; this enum is
// the parsed result of that marker plus body. Block-carrying cases
// (`data`, `totals`, `extremes`, `log`, `profileEvents`) share the
// `tableName + Block` body shape — usually `tableName == ""` for
// non-temporary-table flows but the field is preserved for fidelity.
//
// `tablesStatusResponse` and `partUUIDs` markers are recognized but
// their bodies are unimplemented — the reader throws rather than
// silently misframing subsequent packets.
enum ClickHouseServerPacket: Sendable {

    case hello(ClickHouseServerHelloPacket)
    case data(tableName: String, block: ClickHouseBlock)
    case exception(ClickHouseServerExceptionPacket)
    case progress(ClickHouseServerProgressPacket)
    case pong
    case endOfStream
    case profileInfo(ClickHouseServerProfileInfoPacket)
    case totals(tableName: String, block: ClickHouseBlock)
    case extremes(tableName: String, block: ClickHouseBlock)
    case log(tableName: String, block: ClickHouseBlock)
    case tableColumns(ClickHouseServerTableColumnsPacket)
    case readTaskRequest
    case profileEvents(tableName: String, block: ClickHouseBlock)
    // CH 25.x — session timezone update from server. Carries the
    // timezone string the server has set as the session's default
    // (used for DateTime display formatting). The query lifecycle
    // currently observes this without changing behavior.
    case timezoneUpdate(timezone: String)

}
