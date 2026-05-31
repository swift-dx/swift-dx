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

import Foundation
import NIOCore
import Testing
import DXSQLite

@Suite("DXSQLite public API surface")
struct DXSQLitePublicSurfaceTests {

    struct Person: Codable, Equatable {
        let id: Int
        let name: String
        let score: Double
        let active: Bool
    }

    @Test("a full connect, write, read, and stream cycle works through the public API")
    func endToEnd() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-public-\(UUID().uuidString).sqlite"
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 4))

        try await database.transaction { writer in
            try writer.execute("CREATE TABLE person (id INTEGER PRIMARY KEY, name TEXT, score REAL, active INTEGER)")
            _ = try writer.mutate("INSERT INTO person (id, name, score, active) VALUES (?, ?, ?, ?)", parameters: [1, "Ada", 9.5, true])
            _ = try writer.mutate("INSERT INTO person (id, name, score, active) VALUES (?, ?, ?, ?)", parameters: [2, "Bo", 7.0, false])
        }

        let people = try await database.read { reader in
            try reader.query("SELECT id, name, score, active FROM person ORDER BY id", as: Person.self)
        }
        #expect(people == [Person(id: 1, name: "Ada", score: 9.5, active: true), Person(id: 2, name: "Bo", score: 7.0, active: false)])

        var ids: [Int64] = []
        for try await row in database.readStream("SELECT id FROM person ORDER BY id") {
            ids.append(try row.integer(named: "id"))
        }
        #expect(ids == [1, 2])

        await database.close()
        Self.cleanUp(path)
    }

    @Test("ambient binding exposes the database through current()")
    func ambient() async throws {
        let path = NSTemporaryDirectory() + "dxsqlite-public-\(UUID().uuidString).sqlite"
        try await SQLite.withDatabase(SQLiteConfiguration(location: .file(path: path))) { database in
            try await SQLite.withCurrent(database) {
                let current = try SQLite.current()
                try await current.write { writer in
                    try writer.execute("CREATE TABLE t (v INTEGER)")
                }
            }
        }
        Self.cleanUp(path)
    }

    @Test("current() outside any binding throws noCurrentDatabase")
    func ambientMissing() {
        #expect(throws: SQLiteError.self) {
            _ = try SQLite.current()
        }
    }

    @Test("byte buffer blob values are part of the public surface")
    func byteBufferSurface() throws {
        let value = SQLiteValue(blob: ByteBuffer(bytes: [9, 8, 7]))
        #expect(Array(try value.byteBuffer().readableBytesView) == [9, 8, 7])
    }

    @Test("public enums remain exhaustively reachable from outside the module")
    func publicEnumsArePinned() {
        pin(SQLiteValue.null)
        pin(ColumnType.integer)
        pin(StepOutcome.done)
        pin(SQLiteLocation.inMemory(name: "x"))
        pin(SQLiteError.databaseClosed)
        pin(SQLiteSynchronousMode.normal)
        pin(SQLiteAuthorizerDecision.allow)
        pin(SQLiteAuthorizerAction.select)
    }

    @Test("an authorization policy is constructible through the public API")
    func authorizationPolicyIsPublic() {
        let policy = SQLiteAuthorizationPolicy.custom { action in
            switch action {
            case .insert, .update, .delete: return .deny
            case .read(_, let column) where column == "secret": return .ignore
            default: return .allow
            }
        }
        let configuration = SQLiteConfiguration(location: .inMemory(name: "x"), authorization: policy)
        if case .custom = configuration.authorization {
            #expect(Bool(true))
        } else {
            Issue.record("expected a custom authorization policy")
        }
    }

    private func pin(_ decision: SQLiteAuthorizerDecision) {
        switch decision {
        case .allow, .deny, .ignore: break
        }
    }

    private func pin(_ action: SQLiteAuthorizerAction) {
        switch action {
        case .createIndex, .createTable, .createTemporaryIndex, .createTemporaryTable,
             .createTemporaryTrigger, .createTemporaryView, .createTrigger, .createView,
             .delete, .dropIndex, .dropTable, .dropTemporaryIndex, .dropTemporaryTable,
             .dropTemporaryTrigger, .dropTemporaryView, .dropTrigger, .dropView, .insert,
             .pragma, .read, .select, .transaction, .update, .attach, .detach, .alterTable,
             .reindex, .analyze, .createVirtualTable, .dropVirtualTable, .function,
             .savepoint, .recursive:
            break
        }
    }

    @Test("storage tuning is constructible through the public initializer")
    func tuningIsPublic() {
        let tuning = SQLiteTuning(synchronous: .full, cacheSizeKibibytes: 16_384, mmapSizeBytes: 268_435_456, pageSize: 8192)
        #expect(tuning.synchronous == .full)
        #expect(tuning.cacheSizeKibibytes == 16_384)
        let configuration = SQLiteConfiguration(location: .inMemory(name: "x"), tuning: tuning)
        #expect(configuration.tuning == tuning)
    }

    private func pin(_ mode: SQLiteSynchronousMode) {
        switch mode {
        case .off, .normal, .full, .extra: break
        }
    }

    private func pin(_ value: SQLiteValue) {
        switch value {
        case .null, .integer, .real, .text, .blob: break
        }
    }

    private func pin(_ type: ColumnType) {
        switch type {
        case .null, .integer, .real, .text, .blob: break
        }
    }

    private func pin(_ outcome: StepOutcome) {
        switch outcome {
        case .row, .done: break
        }
    }

    private func pin(_ location: SQLiteLocation) {
        switch location {
        case .file, .inMemory: break
        }
    }

    private func pin(_ error: SQLiteError) {
        switch error {
        case .cannotOpenDatabase, .executeFailed, .prepareFailed, .stepFailed, .bindFailed, .functionRegistrationFailed, .virtualTableRegistrationFailed, .backupFailed, .serializationFailed, .blobFailed, .sessionFailed, .unexpectedColumnType, .columnNotFound, .valueTypeMismatch, .decodingFailed, .encodingFailed, .poolExhausted, .databaseClosed, .noCurrentDatabase: break
        }
    }

    private static func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
