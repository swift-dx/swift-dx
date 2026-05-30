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

struct ClickHouseFloat32Column: ClickHouseColumn {

    var values: [Float32]

    var spec: ClickHouseColumnSpec { .float32 }
    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseFloat32s(values)
    }

    static func decode(rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let values = try buffer.readClickHouseFloat32s(rows: rows)
        return .init(values: values)
    }

}
