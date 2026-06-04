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

// Decodes a single-column result row into a scalar `Decodable` value, reading
// the first column. This is the path taken when the row maps to a plain value
// (a one-column `SELECT`) rather than a struct.
struct PostgresRowSingleValueContainer: SingleValueDecodingContainer {

    let row: PostgresRow
    let codingPath: [CodingKey] = []

    func decodeNil() -> Bool {
        guard case .sqlNull = (try? row.cell(at: 0)) ?? .bytes([]) else { return false }
        return true
    }

    func decode(_ type: Bool.Type) throws -> Bool { try row.decode(Bool.self, at: 0) }
    func decode(_ type: String.Type) throws -> String { try row.decode(String.self, at: 0) }
    func decode(_ type: Double.Type) throws -> Double { try row.decode(Double.self, at: 0) }
    func decode(_ type: Float.Type) throws -> Float { try row.decode(Float.self, at: 0) }

    func decode(_ type: Int.Type) throws -> Int { try narrowing() }
    func decode(_ type: Int8.Type) throws -> Int8 { try narrowing() }
    func decode(_ type: Int16.Type) throws -> Int16 { try narrowing() }
    func decode(_ type: Int32.Type) throws -> Int32 { try narrowing() }
    func decode(_ type: Int64.Type) throws -> Int64 { try narrowing() }
    func decode(_ type: UInt.Type) throws -> UInt { try narrowing() }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try narrowing() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try narrowing() }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try narrowing() }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try narrowing() }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try PostgresRowDecoder.decodeScalar(type, from: row, column: 0)
    }

    private func narrowing<Value: FixedWidthInteger>() throws -> Value {
        let wide = try row.decode(Int.self, at: 0)
        guard let value = Value(exactly: wide) else {
            throw PostgresError.typeDecodingFailed(type: "\(Value.self)", reason: "value \(wide) does not fit \(Value.self)")
        }
        return value
    }
}
