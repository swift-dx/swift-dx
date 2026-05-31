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
import Testing
import DXSQLite

@Suite("DXSQLite authorizer")
struct SQLiteAuthorizerTests {

    static func makePath() -> String {
        NSTemporaryDirectory() + "dxsqlite-authz-\(UUID().uuidString).sqlite"
    }

    static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func seedAccount(_ path: String) async throws {
        let setup = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))
        try await setup.write { writer in
            try writer.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, name TEXT NOT NULL, secret TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO account (id, name, secret) VALUES (1, 'ada', 'token-xyz')", parameters: [])
        }
        await setup.close()
    }

    @Test("an unrestricted policy permits reads and writes")
    func unrestrictedAllowsEverything() async throws {
        let path = Self.makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), authorization: .unrestricted))
        try await database.write { writer in
            try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO t (id, v) VALUES (1, 10)", parameters: [])
        }
        let value = try await database.read { reader in
            try reader.query("SELECT v FROM t WHERE id = 1")[0].integer(named: "v")
        }
        #expect(value == 10)
        await database.close()
        Self.removeFiles(path)
    }

    @Test("a read-only policy denies inserts, updates, and deletes but allows reads")
    func readOnlyPolicyDeniesWrites() async throws {
        let path = Self.makePath()
        try await Self.seedAccount(path)

        let policy = SQLiteAuthorizationPolicy.custom { action in
            switch action {
            case .insert, .update, .delete: return .deny
            default: return .allow
            }
        }
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), authorization: policy))

        let name = try await database.read { reader in
            try reader.query("SELECT name FROM account WHERE id = 1")[0].text(named: "name")
        }
        #expect(name == "ada")

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("INSERT INTO account (id, name, secret) VALUES (2, 'bob', 'token-2')")
            }
        }
        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("UPDATE account SET name = 'mallory' WHERE id = 1")
            }
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("an ignore verdict on a column read redacts it to NULL")
    func ignorePolicyRedactsColumn() async throws {
        let path = Self.makePath()
        try await Self.seedAccount(path)

        let policy = SQLiteAuthorizationPolicy.custom { action in
            if case .read(_, let column) = action, column == "secret" {
                return .ignore
            }
            return .allow
        }
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), authorization: policy))

        let row = try await database.read { reader in
            try reader.query("SELECT name, secret FROM account WHERE id = 1")
        }
        #expect(try row[0].text(named: "name") == "ada")
        #expect(try row[0].value(named: "secret") == .null)

        await database.close()
        Self.removeFiles(path)
    }

    @Test("a policy denying ATTACH blocks attaching another database")
    func denyPolicyBlocksAttach() async throws {
        let path = Self.makePath()
        try await Self.seedAccount(path)

        let policy = SQLiteAuthorizationPolicy.custom { action in
            if case .attach = action {
                return .deny
            }
            return .allow
        }
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), authorization: policy))

        await #expect(throws: SQLiteError.self) {
            try await database.write { writer in
                try writer.execute("ATTACH DATABASE ':memory:' AS aux")
            }
        }

        await database.close()
        Self.removeFiles(path)
    }

    @Test("the policy is enforced on pooled reader connections")
    func policyEnforcedOnPooledReader() async throws {
        let path = Self.makePath()
        try await Self.seedAccount(path)

        let policy = SQLiteAuthorizationPolicy.custom { action in
            if case .read(let table, _) = action, table == "account" {
                return .deny
            }
            return .allow
        }
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path), maxReaders: 2, authorization: policy))

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT name FROM account WHERE id = 1")
            }
        }

        await database.close()
        Self.removeFiles(path)
    }
}
