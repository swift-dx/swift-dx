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

struct ClickHouseFixedWidthIntegerColumn<T: FixedWidthInteger & Sendable>: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    var values: [T]

    var rowCount: Int { values.count }

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseFixedWidthIntegers(values)
    }

    static func decode(spec: ClickHouseColumnSpec, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        let values = try buffer.readClickHouseFixedWidthIntegers(T.self, rows: rows)
        return .init(spec: spec, values: values)
    }

}
