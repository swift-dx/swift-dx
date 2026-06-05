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

/// A borrowed view over one row as it sits in the connection's read buffer. It is
/// handed to the streaming `execute(_:onRow:)` closure and is valid only for the
/// duration of that call: the next row reuses the same buffer. Reading a field as
/// an integer parses it in place with no allocation; reading it as bytes or text
/// copies it out, so a caller pays only for the fields it materializes. To keep a
/// value past the closure, copy it (``bytes(_:)``/``text(_:)``) into your own
/// storage; do not store the view itself.
public struct PostgresRowView {

    private let buffer: ByteBuffer
    private let base: Int

    init(buffer: ByteBuffer, base: Int) {
        self.buffer = buffer
        self.base = base
    }

    public var fieldCount: Int {
        Int(buffer.getInteger(at: base + 5, as: Int16.self) ?? 0)
    }

    public func isNull(_ index: Int) -> Bool {
        locate(index).length < 0
    }

    public func bytes(_ index: Int) throws(PostgresError) -> [UInt8] {
        let field = locate(index)
        guard field.length >= 0 else { throw PostgresError.columnIsNull(column: "\(index)") }
        guard let raw = buffer.getBytes(at: field.valueStart, length: field.length) else {
            throw PostgresError.protocolError(reason: "truncated field at column \(index)")
        }
        return raw
    }

    public func text(_ index: Int) throws(PostgresError) -> String {
        let field = locate(index)
        guard field.length >= 0 else { throw PostgresError.columnIsNull(column: "\(index)") }
        guard let value = buffer.getString(at: field.valueStart, length: field.length) else {
            throw PostgresError.utf8DecodingFailed
        }
        return value
    }

    public func int64(_ index: Int) throws(PostgresError) -> Int64 {
        let field = locate(index)
        guard field.length >= 0 else { throw PostgresError.columnIsNull(column: "\(index)") }
        var value: Int64 = 0
        var cursor = field.valueStart
        let end = field.valueStart + field.length
        let negative = (buffer.getInteger(at: cursor, as: UInt8.self) ?? 0) == 0x2D
        if negative { cursor += 1 }
        while cursor < end {
            value = value * 10 + Int64((buffer.getInteger(at: cursor, as: UInt8.self) ?? 0x30) &- 0x30)
            cursor += 1
        }
        return negative ? -value : value
    }

    private func locate(_ index: Int) -> (valueStart: Int, length: Int) {
        var cursor = base + 7
        var current = 0
        while current < index {
            let length = Int(buffer.getInteger(at: cursor, as: Int32.self) ?? 0)
            cursor += 4 + (length < 0 ? 0 : length)
            current += 1
        }
        return (cursor + 4, Int(buffer.getInteger(at: cursor, as: Int32.self) ?? -1))
    }
}
