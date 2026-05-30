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

// Server-issued schema description for a table being inserted into.
// Sent before the first Data packet of an INSERT to tell the client
// which columns and types it should send. Wire layout:
//   String  name           (table name)
//   String  columns_text   (DDL-style "name1 Type1, name2 Type2, ...")
struct ClickHouseServerTableColumnsPacket: Sendable, Equatable {

    let name: String
    let columnsText: String

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseString(name)
        buffer.writeClickHouseString(columnsText)
    }

    static func decode(from buffer: inout ByteBuffer) throws -> Self {
        let name = try buffer.readClickHouseString()
        let columnsText = try buffer.readClickHouseString()
        return .init(name: name, columnsText: columnsText)
    }

}
