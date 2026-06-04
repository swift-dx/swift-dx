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

// Encodes a list of bound parameters into the text-format cells the extended
// query path sends in a Bind message. Shared by the client and the transaction
// handle so both encode parameters the same way.
enum PostgresParameterEncoding {

    static func cells(from parameters: [any PostgresEncodable]) throws(PostgresError) -> [PostgresCell] {
        var cells: [PostgresCell] = []
        cells.reserveCapacity(parameters.count)
        for parameter in parameters {
            cells.append(try parameter.encodeToText())
        }
        return cells
    }
}
