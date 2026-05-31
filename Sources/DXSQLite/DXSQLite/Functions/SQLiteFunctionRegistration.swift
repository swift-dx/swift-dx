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

import CSQLite

// Boxes a Swift SQL-function body so it can travel through SQLite's void*
// user-data slot. The box holds only an immutable @Sendable closure, so sharing
// it across the per-connection threads that invoke the function is safe.
final class SQLiteFunctionBox: Sendable {

    let body: @Sendable ([SQLiteValue]) throws -> SQLiteValue

    init(body: @escaping @Sendable ([SQLiteValue]) throws -> SQLiteValue) {
        self.body = body
    }
}

// Capture-free @convention(c) entry point SQLite calls per invocation. It
// recovers the box (without changing its retain count — ownership stays with
// SQLite's user-data slot), maps the sqlite3_value arguments to SQLiteValue,
// runs the body, and writes the result or an error back onto the context.
func dxScalarFunctionThunk(_ context: OpaquePointer?, _ argumentCount: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let context, let userData = sqlite3_user_data(context) else { return }
    let box = Unmanaged<SQLiteFunctionBox>.fromOpaque(userData).takeUnretainedValue()
    do {
        let result = try box.body(readFunctionArguments(argumentCount, arguments))
        setFunctionResult(result, on: context)
    } catch {
        sqlite3_result_error(context, "\(error)", -1)
    }
}

// Balances the passRetained at registration. SQLite invokes this when the
// function is removed, when the connection closes, or if registration fails.
func dxFunctionDestroyThunk(_ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<SQLiteFunctionBox>.fromOpaque(userData).release()
}

func readFunctionArguments(_ count: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?) -> [SQLiteValue] {
    guard let arguments, count > 0 else { return [] }
    var values: [SQLiteValue] = []
    var index = 0
    while index < Int(count) {
        values.append(readFunctionValue(arguments[index]))
        index += 1
    }
    return values
}

func readFunctionValue(_ value: OpaquePointer?) -> SQLiteValue {
    guard let value else { return .null }
    switch sqlite3_value_type(value) {
    case SQLITE_INTEGER: return .integer(sqlite3_value_int64(value))
    case SQLITE_FLOAT: return .real(sqlite3_value_double(value))
    case SQLITE_TEXT: return .text(readFunctionText(value))
    case SQLITE_BLOB: return .blob(readFunctionBlob(value))
    default: return .null
    }
}

func readFunctionText(_ value: OpaquePointer) -> String {
    guard let bytes = sqlite3_value_text(value) else { return "" }
    return String(cString: bytes)
}

func readFunctionBlob(_ value: OpaquePointer) -> [UInt8] {
    let count = Int(sqlite3_value_bytes(value))
    guard count > 0, let pointer = sqlite3_value_blob(value) else { return [] }
    return Array(UnsafeRawBufferPointer(start: pointer, count: count))
}

func setFunctionResult(_ value: SQLiteValue, on context: OpaquePointer) {
    switch value {
    case .null: sqlite3_result_null(context)
    case .integer(let integer): sqlite3_result_int64(context, integer)
    case .real(let double): sqlite3_result_double(context, double)
    case .text(let string): string.withCString { dx_sqlite3_result_text_transient(context, $0, -1) }
    case .blob(let bytes): bytes.withUnsafeBytes { dx_sqlite3_result_blob_transient(context, $0.baseAddress, Int32($0.count)) }
    }
}
