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

// Renders one row into PostgreSQL's COPY text format: tab-separated column
// values terminated by a newline, with backslash, tab, newline, and carriage
// return escaped, and SQL NULL written as the two-byte sequence `\N`. The column
// text is the type's own input representation (the same text the parameter
// encoders produce), which COPY feeds through each column's input function.
enum PostgresCopyTextEncoding {

    private static let tab: UInt8 = 0x09
    private static let newline: UInt8 = 0x0a
    private static let backslash: UInt8 = 0x5c

    static func line(_ cells: [PostgresCell]) -> [UInt8] {
        var output: [UInt8] = []
        for (offset, cell) in cells.enumerated() {
            if offset > 0 { output.append(tab) }
            appendCell(cell, into: &output)
        }
        output.append(newline)
        return output
    }

    private static func appendCell(_ cell: PostgresCell, into output: inout [UInt8]) {
        switch cell {
        case .sqlNull:
            output.append(backslash)
            output.append(0x4e)
        case .bytes(let bytes):
            for byte in bytes {
                appendEscapedByte(byte, into: &output)
            }
        }
    }

    private static func appendEscapedByte(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case backslash: output.append(backslash); output.append(backslash)
        case tab: output.append(backslash); output.append(0x74)
        case newline: output.append(backslash); output.append(0x6e)
        case 0x0d: output.append(backslash); output.append(0x72)
        default: output.append(byte)
        }
    }
}
