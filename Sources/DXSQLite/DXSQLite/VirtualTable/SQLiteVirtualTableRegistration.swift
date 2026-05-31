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

// Owns one registered virtual-table module for the lifetime of a connection.
// The module struct is heap-allocated because sqlite3_create_module stores the
// pointer rather than copying it, so it must outlive the connection; the
// connection holds this registration and frees the module after the handle is
// closed. The provider travels into SQLite's per-module client-data slot as an
// unretained pointer, kept alive by this same registration.
final class SQLiteVirtualTableRegistration {

    let provider: any SQLiteTableProvider
    let modulePointer: UnsafeMutablePointer<sqlite3_module>

    init(provider: any SQLiteTableProvider) {
        self.provider = provider
        let pointer = UnsafeMutablePointer<sqlite3_module>.allocate(capacity: 1)
        pointer.initialize(to: makeVirtualTableModule())
        self.modulePointer = pointer
    }

    deinit {
        modulePointer.deinitialize(count: 1)
        modulePointer.deallocate()
    }
}

// Holds one scan's snapshot of rows and the cursor's position within it. Lives
// on a single connection thread for a single scan, retained into the cursor's
// box at xFilter and released at xClose, so it is never shared concurrently.
final class SQLiteVirtualTableCursorState {

    let rows: [[SQLiteValue]]
    var rowIndex: Int = 0

    init(rows: [[SQLiteValue]]) {
        self.rows = rows
    }
}

func makeVirtualTableModule() -> sqlite3_module {
    var module = sqlite3_module()
    module.iVersion = 1
    module.xConnect = dxVtabConnect
    module.xBestIndex = dxVtabBestIndex
    module.xDisconnect = dxVtabDisconnect
    module.xOpen = dxVtabOpen
    module.xClose = dxVtabClose
    module.xFilter = dxVtabFilter
    module.xNext = dxVtabNext
    module.xEof = dxVtabEof
    module.xColumn = dxVtabColumn
    module.xRowid = dxVtabRowid
    return module
}

func dxVtabConnect(_ database: OpaquePointer?, _ clientData: UnsafeMutableRawPointer?, _ argumentCount: Int32, _ arguments: UnsafePointer<UnsafePointer<CChar>?>?, _ table: UnsafeMutablePointer<UnsafeMutablePointer<sqlite3_vtab>?>?, _ errorMessage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let database, let clientData, let table else { return SQLITE_ERROR }
    return connectVirtualTable(database, registration: clientData, output: table)
}

private func connectVirtualTable(_ database: OpaquePointer, registration clientData: UnsafeMutableRawPointer, output table: UnsafeMutablePointer<UnsafeMutablePointer<sqlite3_vtab>?>) -> Int32 {
    let registration = Unmanaged<SQLiteVirtualTableRegistration>.fromOpaque(clientData).takeUnretainedValue()
    let declareCode = registration.provider.schema.withCString { sqlite3_declare_vtab(database, $0) }
    guard declareCode == SQLITE_OK else { return declareCode }
    guard let allocated = dx_vtab_alloc() else { return SQLITE_NOMEM }
    dx_vtab_set_box(allocated, clientData)
    table.pointee = allocated
    return SQLITE_OK
}

func dxVtabBestIndex(_ table: UnsafeMutablePointer<sqlite3_vtab>?, _ indexInformation: UnsafeMutablePointer<sqlite3_index_info>?) -> Int32 {
    guard let indexInformation else { return SQLITE_ERROR }
    indexInformation.pointee.estimatedCost = 1_000_000
    return SQLITE_OK
}

func dxVtabDisconnect(_ table: UnsafeMutablePointer<sqlite3_vtab>?) -> Int32 {
    dx_vtab_free(table)
    return SQLITE_OK
}

func dxVtabOpen(_ table: UnsafeMutablePointer<sqlite3_vtab>?, _ cursor: UnsafeMutablePointer<UnsafeMutablePointer<sqlite3_vtab_cursor>?>?) -> Int32 {
    guard let cursor, let allocated = dx_vtab_cursor_alloc() else { return SQLITE_NOMEM }
    cursor.pointee = allocated
    return SQLITE_OK
}

func dxVtabClose(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?) -> Int32 {
    guard let cursor else { return SQLITE_OK }
    releaseCursorState(dx_vtab_cursor_box(cursor))
    dx_vtab_cursor_free(cursor)
    return SQLITE_OK
}

func dxVtabFilter(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?, _ indexNumber: Int32, _ indexString: UnsafePointer<CChar>?, _ argumentCount: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?) -> Int32 {
    guard let cursor, let table = dx_vtab_cursor_table(cursor) else { return SQLITE_ERROR }
    return startScan(cursor, table: table)
}

private func startScan(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>, table: UnsafeMutablePointer<sqlite3_vtab>) -> Int32 {
    guard let clientData = dx_vtab_box(table) else { return SQLITE_ERROR }
    let registration = Unmanaged<SQLiteVirtualTableRegistration>.fromOpaque(clientData).takeUnretainedValue()
    releaseCursorState(dx_vtab_cursor_box(cursor))
    let state = SQLiteVirtualTableCursorState(rows: registration.provider.rows())
    dx_vtab_cursor_set_box(cursor, Unmanaged.passRetained(state).toOpaque())
    return SQLITE_OK
}

func dxVtabNext(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?) -> Int32 {
    guard let state = cursorState(cursor) else { return SQLITE_ERROR }
    state.rowIndex += 1
    return SQLITE_OK
}

func dxVtabEof(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?) -> Int32 {
    guard let state = cursorState(cursor) else { return 1 }
    return state.rowIndex >= state.rows.count ? 1 : 0
}

func dxVtabColumn(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?, _ context: OpaquePointer?, _ columnIndex: Int32) -> Int32 {
    guard let context, let state = cursorState(cursor) else { return SQLITE_ERROR }
    return emitColumn(context, state: state, columnIndex: columnIndex)
}

private func emitColumn(_ context: OpaquePointer, state: SQLiteVirtualTableCursorState, columnIndex: Int32) -> Int32 {
    guard state.rowIndex < state.rows.count else { return SQLITE_ERROR }
    let row = state.rows[state.rowIndex]
    guard Int(columnIndex) < row.count else {
        setFunctionResult(.null, on: context)
        return SQLITE_OK
    }
    setFunctionResult(row[Int(columnIndex)], on: context)
    return SQLITE_OK
}

func dxVtabRowid(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?, _ rowID: UnsafeMutablePointer<sqlite3_int64>?) -> Int32 {
    guard let rowID, let state = cursorState(cursor) else { return SQLITE_ERROR }
    rowID.pointee = Int64(state.rowIndex)
    return SQLITE_OK
}

private func cursorState(_ cursor: UnsafeMutablePointer<sqlite3_vtab_cursor>?) -> SQLiteVirtualTableCursorState? {
    guard let cursor, let box = dx_vtab_cursor_box(cursor) else { return nil }
    return Unmanaged<SQLiteVirtualTableCursorState>.fromOpaque(box).takeUnretainedValue()
}

private func releaseCursorState(_ box: UnsafeMutableRawPointer?) {
    guard let box else { return }
    Unmanaged<SQLiteVirtualTableCursorState>.fromOpaque(box).release()
}
