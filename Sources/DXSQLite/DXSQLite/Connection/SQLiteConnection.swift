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

// One open SQLite connection. @unchecked Sendable is safe because the engine is
// compiled SQLITE_THREADSAFE=2 (a handle may move between threads as long as it
// is never used concurrently) and the pool guarantees exactly that: the writer
// connection is serialized on one dedicated thread, and each reader connection
// is checked out to a single in-flight read at a time. The handle is never
// shared across concurrent calls.
final class SQLiteConnection: @unchecked Sendable {

    private let handle: OpaquePointer
    private var traceBox = SQLiteTraceBox { _ in }
    private var busyBox = SQLiteBusyBox { _ in false }
    private var progressBox = SQLiteProgressBox { true }
    private var virtualTableRegistrations: [SQLiteVirtualTableRegistration] = []
    private var authorizerBox = SQLiteAuthorizerBox { _ in .allow }
    private var isOpen = true

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    static func open(_ location: SQLiteLocation, readOnly: Bool, customizations: SQLiteConnectionCustomizations) throws(SQLiteError) -> SQLiteConnection {
        var handleOut: OpaquePointer? = nil
        let code = sqlite3_open_v2(location.resolvedPath, &handleOut, openFlags(readOnly: readOnly), nil)
        guard let handle = handleOut else {
            throw SQLiteError.cannotOpenDatabase(path: location.resolvedPath, code: code, message: "database handle was not allocated")
        }
        guard code == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            throw SQLiteError.cannotOpenDatabase(path: location.resolvedPath, code: code, message: message)
        }
        let connection = SQLiteConnection(handle: handle)
        try connection.apply(customizations)
        return connection
    }

    func execute(_ sql: String) throws(SQLiteError) {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw SQLiteError.executeFailed(sql: sql, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func prepare(_ sql: String) throws(SQLiteError) -> SQLiteStatement {
        var statementOut: OpaquePointer? = nil
        let code = sqlite3_prepare_v2(handle, sql, -1, &statementOut, nil)
        guard let statement = statementOut else {
            throw SQLiteError.prepareFailed(sql: sql, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        guard code == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SQLiteError.prepareFailed(sql: sql, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: statement)
    }

    func query(_ sql: String, _ parameters: [SQLiteValue]) throws(SQLiteError) -> [SQLiteRow] {
        let statement = try prepare(sql)
        try statement.bindAll(parameters)
        return try statement.collectRows()
    }

    func streamRows(_ sql: String, _ parameters: [SQLiteValue], onRow: (SQLiteRow) -> Bool) throws(SQLiteError) {
        let statement = try prepare(sql)
        try statement.bindAll(parameters)
        try statement.forEachRow(onRow)
    }

    func backup(toFile path: String) throws(SQLiteError) {
        var destinationHandle: OpaquePointer? = nil
        let openCode = sqlite3_open_v2(path, &destinationHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, nil)
        guard let destination = destinationHandle else {
            throw SQLiteError.backupFailed(code: openCode, message: "could not open backup destination at \(path)")
        }
        defer { sqlite3_close_v2(destination) }
        guard openCode == SQLITE_OK else {
            throw SQLiteError.backupFailed(code: openCode, message: String(cString: sqlite3_errmsg(destination)))
        }
        try runBackup(to: destination)
    }

    private func runBackup(to destination: OpaquePointer) throws(SQLiteError) {
        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
            throw SQLiteError.backupFailed(code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
        let stepCode = sqlite3_backup_step(backup, -1)
        let finishCode = sqlite3_backup_finish(backup)
        try checkBackup(stepCode: stepCode, finishCode: finishCode, destination: destination)
    }

    private func checkBackup(stepCode: Int32, finishCode: Int32, destination: OpaquePointer) throws(SQLiteError) {
        guard stepCode == SQLITE_DONE else {
            throw SQLiteError.backupFailed(code: stepCode, message: String(cString: sqlite3_errmsg(destination)))
        }
        guard finishCode == SQLITE_OK else {
            throw SQLiteError.backupFailed(code: finishCode, message: String(cString: sqlite3_errmsg(destination)))
        }
    }

    func serialize() throws(SQLiteError) -> [UInt8] {
        var size: Int64 = 0
        guard let buffer = sqlite3_serialize(handle, "main", &size, 0) else {
            throw SQLiteError.serializationFailed(message: "sqlite3_serialize returned no buffer")
        }
        defer { sqlite3_free(buffer) }
        return Array(UnsafeRawBufferPointer(start: buffer, count: Int(size)))
    }

    func withBlob<Value>(table: String, column: String, rowID: Int64, readOnly: Bool, _ body: (SQLiteBlob) throws -> Value) throws -> Value {
        var blobHandle: OpaquePointer? = nil
        let code = sqlite3_blob_open(handle, "main", table, column, rowID, blobFlags(readOnly: readOnly), &blobHandle)
        guard let opened = blobHandle else {
            throw SQLiteError.blobFailed(operation: "open \(table).\(column)", code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        let blob = SQLiteBlob(handle: opened, connection: handle)
        defer { blob.close() }
        return try body(blob)
    }

    private func blobFlags(readOnly: Bool) -> Int32 {
        readOnly ? 0 : 1
    }

    func recordingChangeset(_ body: () throws -> Void) throws -> [UInt8] {
        var sessionHandle: OpaquePointer? = nil
        let createCode = sqlite3session_create(handle, "main", &sessionHandle)
        guard let session = sessionHandle else {
            throw SQLiteError.sessionFailed(operation: "create", code: createCode, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3session_delete(session) }
        let attachCode = sqlite3session_attach(session, nil)
        guard attachCode == SQLITE_OK else {
            throw SQLiteError.sessionFailed(operation: "attach", code: attachCode, message: String(cString: sqlite3_errmsg(handle)))
        }
        try body()
        return try captureChangeset(session)
    }

    private func captureChangeset(_ session: OpaquePointer) throws(SQLiteError) -> [UInt8] {
        var size: Int32 = 0
        var buffer: UnsafeMutableRawPointer? = nil
        let code = sqlite3session_changeset(session, &size, &buffer)
        guard code == SQLITE_OK, let buffer else {
            throw SQLiteError.sessionFailed(operation: "changeset", code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_free(buffer) }
        return Array(UnsafeRawBufferPointer(start: buffer, count: Int(size)))
    }

    func applyChangeset(_ changeset: [UInt8]) throws(SQLiteError) {
        let code = changeset.withUnsafeBytes { raw in
            sqlite3changeset_apply(handle, Int32(raw.count), UnsafeMutableRawPointer(mutating: raw.baseAddress), nil, dxChangesetConflictThunk, nil)
        }
        guard code == SQLITE_OK else {
            throw SQLiteError.sessionFailed(operation: "apply", code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func register(_ function: SQLiteFunction) throws(SQLiteError) {
        let box = SQLiteFunctionBox(body: function.body)
        let context = Unmanaged.passRetained(box).toOpaque()
        let code = sqlite3_create_function_v2(handle, function.name, Int32(function.argumentCount), SQLITE_UTF8, context, dxScalarFunctionThunk, nil, nil, dxFunctionDestroyThunk)
        guard code == SQLITE_OK else {
            throw SQLiteError.functionRegistrationFailed(name: function.name, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func applyFunctions(_ functions: [SQLiteFunction]) throws(SQLiteError) {
        for function in functions {
            try register(function)
        }
    }

    func registerAggregate(_ aggregate: SQLiteAggregate) throws(SQLiteError) {
        let box = SQLiteAggregateBox(makeAggregator: aggregate.makeAggregator)
        let context = Unmanaged.passRetained(box).toOpaque()
        let code = sqlite3_create_function_v2(handle, aggregate.name, Int32(aggregate.argumentCount), SQLITE_UTF8, context, nil, dxAggregateStepThunk, dxAggregateFinalThunk, dxAggregateDestroyThunk)
        guard code == SQLITE_OK else {
            throw SQLiteError.functionRegistrationFailed(name: aggregate.name, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func applyAggregates(_ aggregates: [SQLiteAggregate]) throws(SQLiteError) {
        for aggregate in aggregates {
            try registerAggregate(aggregate)
        }
    }

    func registerCollation(_ collation: SQLiteCollation) throws(SQLiteError) {
        let box = SQLiteCollationBox(compare: collation.compare)
        let context = Unmanaged.passRetained(box).toOpaque()
        let code = sqlite3_create_collation_v2(handle, collation.name, SQLITE_UTF8, context, dxCollationThunk, dxCollationDestroyThunk)
        guard code == SQLITE_OK else {
            Unmanaged<SQLiteCollationBox>.fromOpaque(context).release()
            throw SQLiteError.functionRegistrationFailed(name: collation.name, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func applyCollations(_ collations: [SQLiteCollation]) throws(SQLiteError) {
        for collation in collations {
            try registerCollation(collation)
        }
    }

    func registerVirtualTable(_ provider: any SQLiteTableProvider) throws(SQLiteError) {
        let registration = SQLiteVirtualTableRegistration(provider: provider)
        let clientData = Unmanaged.passUnretained(registration).toOpaque()
        let code = sqlite3_create_module(handle, provider.name, registration.modulePointer, clientData)
        guard code == SQLITE_OK else {
            throw SQLiteError.virtualTableRegistrationFailed(name: provider.name, code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        virtualTableRegistrations.append(registration)
    }

    private func applyVirtualTables(_ providers: [any SQLiteTableProvider]) throws(SQLiteError) {
        for provider in providers {
            try registerVirtualTable(provider)
        }
    }

    private func applyTuning(_ tuning: SQLiteTuning) throws(SQLiteError) {
        try execute("PRAGMA page_size=\(tuning.pageSize);")
        try execute("PRAGMA cache_size=-\(tuning.cacheSizeKibibytes);")
        try execute("PRAGMA mmap_size=\(tuning.mmapSizeBytes);")
        try execute("PRAGMA synchronous=\(tuning.synchronous.pragmaKeyword);")
    }

    private func apply(_ customizations: SQLiteConnectionCustomizations) throws(SQLiteError) {
        try applyTuning(customizations.tuning)
        try applyFunctions(customizations.functions)
        try applyAggregates(customizations.aggregates)
        try applyCollations(customizations.collations)
        try applyVirtualTables(customizations.virtualTables)
    }

    func installAuthorizer(_ policy: SQLiteAuthorizationPolicy) {
        guard case .custom(let decide) = policy else { return }
        let box = SQLiteAuthorizerBox(decide: decide)
        sqlite3_set_authorizer(handle, dxAuthorizerThunk, Unmanaged.passUnretained(box).toOpaque())
        authorizerBox = box
    }

    private func clearAuthorizer() {
        sqlite3_set_authorizer(handle, nil, nil)
    }

    func setUpdateHook(_ box: SQLiteUpdateHookBox) {
        let context = Unmanaged.passRetained(box).toOpaque()
        releaseHookPointer(sqlite3_update_hook(handle, dxUpdateHookThunk, context))
    }

    func setCommitHook(_ box: SQLiteCommitHookBox) {
        let context = Unmanaged.passRetained(box).toOpaque()
        releaseHookPointer(sqlite3_commit_hook(handle, dxCommitHookThunk, context))
    }

    func setRollbackHook(_ box: SQLiteRollbackHookBox) {
        let context = Unmanaged.passRetained(box).toOpaque()
        releaseHookPointer(sqlite3_rollback_hook(handle, dxRollbackHookThunk, context))
    }

    private func clearHooks() {
        releaseHookPointer(sqlite3_update_hook(handle, nil, nil))
        releaseHookPointer(sqlite3_commit_hook(handle, nil, nil))
        releaseHookPointer(sqlite3_rollback_hook(handle, nil, nil))
    }

    private func releaseHookPointer(_ pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }

    func setTrace(_ box: SQLiteTraceBox) {
        sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_STMT), dxTraceThunk, Unmanaged.passUnretained(box).toOpaque())
        traceBox = box
    }

    func setBusy(_ box: SQLiteBusyBox) {
        sqlite3_busy_handler(handle, dxBusyThunk, Unmanaged.passUnretained(box).toOpaque())
        busyBox = box
    }

    func setProgress(_ box: SQLiteProgressBox, instructionInterval: Int32) {
        sqlite3_progress_handler(handle, instructionInterval, dxProgressThunk, Unmanaged.passUnretained(box).toOpaque())
        progressBox = box
    }

    private func clearObservers() {
        sqlite3_trace_v2(handle, 0, nil, nil)
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_busy_handler(handle, nil, nil)
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    var changedRowCount: Int {
        Int(sqlite3_changes64(handle))
    }

    private static func openFlags(readOnly: Bool) -> Int32 {
        readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        clearHooks()
        clearObservers()
        clearAuthorizer()
        sqlite3_close_v2(handle)
    }

    deinit {
        close()
    }
}
