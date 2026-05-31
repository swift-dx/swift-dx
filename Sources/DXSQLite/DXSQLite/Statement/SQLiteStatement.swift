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

// A prepared statement bound to one connection. @unchecked Sendable is safe
// because a statement is only ever driven by the single task that holds the
// owning connection: the writer uses its statements on the writer's dedicated
// thread, and each reader statement lives entirely inside one checked-out read.
// The sqlite3_stmt handle is never touched concurrently.
final class SQLiteStatement: @unchecked Sendable {

    private let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    var columnCount: Int {
        Int(sqlite3_column_count(handle))
    }

    func bindAll(_ values: [SQLiteValue]) throws(SQLiteError) {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws(SQLiteError) {
        let code = bindCode(value, at: index)
        guard code == SQLITE_OK else {
            throw SQLiteError.bindFailed(parameterIndex: index, code: code, message: handleMessage)
        }
    }

    func step() throws(SQLiteError) -> StepOutcome {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: throw SQLiteError.stepFailed(code: code, message: handleMessage)
        }
    }

    func column(at index: Int32) throws(SQLiteError) -> SQLiteValue {
        let rawType = sqlite3_column_type(handle, index)
        switch rawType {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(handle, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(handle, index))
        case SQLITE_TEXT: return .text(readText(at: index))
        case SQLITE_BLOB: return .blob(readBlob(at: index))
        case SQLITE_NULL: return .null
        default: throw SQLiteError.unexpectedColumnType(columnIndex: index, rawType: rawType)
        }
    }

    func collectRows() throws(SQLiteError) -> [SQLiteRow] {
        var rows: [SQLiteRow] = []
        try forEachRow { rows.append($0) }
        return rows
    }

    func forEachRow(_ body: (SQLiteRow) -> Void) throws(SQLiteError) {
        let names = columnNames()
        while try step() == .row {
            body(try readRow(names: names))
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    private func readRow(names: [String]) throws(SQLiteError) -> SQLiteRow {
        var values: [SQLiteValue] = []
        var index: Int32 = 0
        while index < Int32(names.count) {
            values.append(try column(at: index))
            index += 1
        }
        return SQLiteRow(columns: values, columnNames: names)
    }

    private func columnNames() -> [String] {
        var names: [String] = []
        var index: Int32 = 0
        while index < Int32(columnCount) {
            names.append(columnName(at: index))
            index += 1
        }
        return names
    }

    private func columnName(at index: Int32) -> String {
        guard let name = sqlite3_column_name(handle, index) else { return "" }
        return String(cString: name)
    }

    private func bindCode(_ value: SQLiteValue, at index: Int32) -> Int32 {
        switch value {
        case .null: sqlite3_bind_null(handle, index)
        case .integer(let integer): sqlite3_bind_int64(handle, index, integer)
        case .real(let double): sqlite3_bind_double(handle, index, double)
        case .text(let string): string.withCString { dx_sqlite3_bind_text_transient(handle, index, $0, -1) }
        case .blob(let bytes): bindBlob(bytes, at: index)
        }
    }

    private func bindBlob(_ bytes: [UInt8], at index: Int32) -> Int32 {
        bytes.withUnsafeBytes { buffer in
            dx_sqlite3_bind_blob_transient(handle, index, buffer.baseAddress, Int32(buffer.count))
        }
    }

    private func readText(at index: Int32) -> String {
        guard let bytes = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: bytes)
    }

    private func readBlob(at index: Int32) -> [UInt8] {
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0, let pointer = sqlite3_column_blob(handle, index) else { return [] }
        return Array(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    private var handleMessage: String {
        String(cString: sqlite3_errmsg(sqlite3_db_handle(handle)))
    }

    deinit {
        sqlite3_finalize(handle)
    }
}
