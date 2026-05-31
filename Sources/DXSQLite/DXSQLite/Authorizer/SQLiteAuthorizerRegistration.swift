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
import DXCore

// Holds the authorizer decision function. The connection owns this box for its
// lifetime and hands SQLite an unretained pointer, because sqlite3_set_authorizer
// takes no destructor callback to balance a retain; the connection clears the
// authorizer before it closes. Sendable because the immutable @Sendable closure
// is the only stored state.
final class SQLiteAuthorizerBox: Sendable {

    let decide: @Sendable (SQLiteAuthorizerAction) -> SQLiteAuthorizerDecision

    init(decide: @escaping @Sendable (SQLiteAuthorizerAction) -> SQLiteAuthorizerDecision) {
        self.decide = decide
    }
}

extension SQLiteAuthorizerDecision {

    var code: Int32 {
        switch self {
        case .allow: SQLITE_OK
        case .deny: SQLITE_DENY
        case .ignore: SQLITE_IGNORE
        }
    }
}

// Capture-free @convention(c) entry point SQLite calls once per action while it
// compiles a statement. An action code DXSQLite does not model is denied rather
// than silently allowed, so a future or unrecognized action cannot bypass a
// policy.
func dxAuthorizerThunk(_ userData: UnsafeMutableRawPointer?, _ actionCode: Int32, _ firstArgument: UnsafePointer<CChar>?, _ secondArgument: UnsafePointer<CChar>?, _ databaseName: UnsafePointer<CChar>?, _ triggerName: UnsafePointer<CChar>?) -> Int32 {
    guard let userData else { return SQLITE_DENY }
    let box = Unmanaged<SQLiteAuthorizerBox>.fromOpaque(userData).takeUnretainedValue()
    switch makeAuthorizerAction(actionCode, firstArgument, secondArgument) {
    case .found(let action): return box.decide(action).code
    case .notFound: return SQLITE_DENY
    }
}

func authorizerString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

func makeAuthorizerAction(_ actionCode: Int32, _ firstArgument: UnsafePointer<CChar>?, _ secondArgument: UnsafePointer<CChar>?) -> Lookup<SQLiteAuthorizerAction> {
    let first = authorizerString(firstArgument)
    let second = authorizerString(secondArgument)
    switch actionCode {
    case SQLITE_CREATE_INDEX: return .found(.createIndex(index: first, table: second))
    case SQLITE_CREATE_TABLE: return .found(.createTable(table: first))
    case SQLITE_CREATE_TEMP_INDEX: return .found(.createTemporaryIndex(index: first, table: second))
    case SQLITE_CREATE_TEMP_TABLE: return .found(.createTemporaryTable(table: first))
    case SQLITE_CREATE_TEMP_TRIGGER: return .found(.createTemporaryTrigger(trigger: first, table: second))
    case SQLITE_CREATE_TEMP_VIEW: return .found(.createTemporaryView(view: first))
    case SQLITE_CREATE_TRIGGER: return .found(.createTrigger(trigger: first, table: second))
    case SQLITE_CREATE_VIEW: return .found(.createView(view: first))
    case SQLITE_DELETE: return .found(.delete(table: first))
    case SQLITE_DROP_INDEX: return .found(.dropIndex(index: first, table: second))
    case SQLITE_DROP_TABLE: return .found(.dropTable(table: first))
    case SQLITE_DROP_TEMP_INDEX: return .found(.dropTemporaryIndex(index: first, table: second))
    case SQLITE_DROP_TEMP_TABLE: return .found(.dropTemporaryTable(table: first))
    case SQLITE_DROP_TEMP_TRIGGER: return .found(.dropTemporaryTrigger(trigger: first, table: second))
    case SQLITE_DROP_TEMP_VIEW: return .found(.dropTemporaryView(view: first))
    case SQLITE_DROP_TRIGGER: return .found(.dropTrigger(trigger: first, table: second))
    case SQLITE_DROP_VIEW: return .found(.dropView(view: first))
    case SQLITE_INSERT: return .found(.insert(table: first))
    case SQLITE_PRAGMA: return .found(.pragma(name: first, argument: second))
    case SQLITE_READ: return .found(.read(table: first, column: second))
    case SQLITE_SELECT: return .found(.select)
    case SQLITE_TRANSACTION: return .found(.transaction(operation: first))
    case SQLITE_UPDATE: return .found(.update(table: first, column: second))
    case SQLITE_ATTACH: return .found(.attach(file: first))
    case SQLITE_DETACH: return .found(.detach(database: first))
    case SQLITE_ALTER_TABLE: return .found(.alterTable(database: first, table: second))
    case SQLITE_REINDEX: return .found(.reindex(index: first))
    case SQLITE_ANALYZE: return .found(.analyze(table: first))
    case SQLITE_CREATE_VTABLE: return .found(.createVirtualTable(table: first, module: second))
    case SQLITE_DROP_VTABLE: return .found(.dropVirtualTable(table: first, module: second))
    case SQLITE_FUNCTION: return .found(.function(name: second))
    case SQLITE_SAVEPOINT: return .found(.savepoint(operation: first, name: second))
    case SQLITE_RECURSIVE: return .found(.recursive)
    default: return .notFound
    }
}
