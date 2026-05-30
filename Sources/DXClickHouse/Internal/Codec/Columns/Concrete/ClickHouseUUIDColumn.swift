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

import Foundation
import NIOCore

struct ClickHouseUUIDColumn: ClickHouseColumn {

    var values: [UUID]

    var spec: ClickHouseColumnSpec { .uuid }
    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseUUIDs(values)
    }

    static func decode(rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let values = try buffer.readClickHouseUUIDs(rows: rows)
        return .init(values: values)
    }

}
