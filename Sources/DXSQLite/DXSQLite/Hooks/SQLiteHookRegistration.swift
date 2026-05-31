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

// The hook setters have no xDestroy: each returns the prior user-data pointer.
// The connection retains a box when installing a hook and releases whatever the
// setter returns (the box it replaced); installing nil on close recovers and
// releases the last box. Each box holds only an immutable @Sendable closure.
final class SQLiteUpdateHookBox: Sendable {

    let handler: @Sendable (SQLiteChange) -> Void

    init(handler: @escaping @Sendable (SQLiteChange) -> Void) {
        self.handler = handler
    }
}

final class SQLiteCommitHookBox: Sendable {

    let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

final class SQLiteRollbackHookBox: Sendable {

    let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

func dxUpdateHookThunk(_ userData: UnsafeMutableRawPointer?, _ operation: Int32, _ databaseName: UnsafePointer<CChar>?, _ tableName: UnsafePointer<CChar>?, _ rowID: Int64) {
    guard let userData else { return }
    let box = Unmanaged<SQLiteUpdateHookBox>.fromOpaque(userData).takeUnretainedValue()
    box.handler(SQLiteChange(operation: hookOperation(operation), databaseName: hookString(databaseName), tableName: hookString(tableName), rowID: rowID))
}

func dxCommitHookThunk(_ userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let userData else { return 0 }
    Unmanaged<SQLiteCommitHookBox>.fromOpaque(userData).takeUnretainedValue().handler()
    return 0
}

func dxRollbackHookThunk(_ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<SQLiteRollbackHookBox>.fromOpaque(userData).takeUnretainedValue().handler()
}

private func hookOperation(_ raw: Int32) -> SQLiteChangeOperation {
    switch raw {
    case SQLITE_INSERT: return .insert
    case SQLITE_DELETE: return .delete
    default: return .update
    }
}

private func hookString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}
