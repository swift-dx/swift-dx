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

// Tagged union of every client-to-server packet variant we emit.
// `tablesStatusRequest` is deferred until we have a need for it.
enum ClickHouseClientPacket: Sendable {

    case hello(ClickHouseClientHelloPacket)
    case query(ClickHouseQueryPacket)
    case data(tableName: String, block: ClickHouseBlock)
    case cancel
    case ping

}
