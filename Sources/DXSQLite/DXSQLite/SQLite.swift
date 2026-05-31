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

/// Entry point to DXSQLite.
///
/// `SQLite` is a namespace, not a value you hold onto. It opens a
/// ``SQLiteDatabase`` — the long-lived, pooled handle that carries every
/// operation. Open one at startup and share it for the process lifetime.
///
/// ## Long-lived application database
///
/// ```swift
/// let database = try await SQLite.connect(.init(location: .file(path: "app.sqlite")))
/// try await database.write { writer in
///     try writer.execute("CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT)")
///     _ = try writer.mutate("INSERT INTO item(name) VALUES (?)", parameters: [.text("Ada")])
/// }
/// let rows = try await database.read { reader in
///     try reader.query("SELECT name FROM item")
/// }
/// ```
///
/// `SQLiteDatabase` conforms to ServiceLifecycle's `Service`, so it can run
/// inside a `ServiceGroup` and tear its pools down on graceful shutdown.
///
/// ## Scoped usage
///
/// ``withDatabase(_:_:)`` connects, runs the body, then closes whether the body
/// returns or throws — for scripts, tests, and one-off tools.
///
/// ## Ambient access
///
/// Bind one database for a scope with ``withCurrent(_:_:)`` and read it back
/// with ``current()`` from code that was never handed the database. Reading
/// outside any binding throws ``SQLiteError/noCurrentDatabase``.
public enum SQLite {

    enum Ambient: Sendable {

        case unbound
        case bound(SQLiteDatabase)
    }

    @TaskLocal static var ambient: Ambient = .unbound

    public static func connect(_ configuration: SQLiteConfiguration) async throws(SQLiteError) -> SQLiteDatabase {
        try SQLiteDatabase.open(configuration)
    }

    public static func withDatabase<Result>(_ configuration: SQLiteConfiguration, _ body: (SQLiteDatabase) async throws -> Result) async throws -> Result {
        let database = try await connect(configuration)
        do {
            let result = try await body(database)
            await database.close()
            return result
        } catch {
            await database.close()
            throw error
        }
    }

    public static func withCurrent<Result>(_ database: SQLiteDatabase, _ body: () async throws -> Result) async rethrows -> Result {
        try await $ambient.withValue(.bound(database)) {
            try await body()
        }
    }

    public static func current() throws(SQLiteError) -> SQLiteDatabase {
        guard case .bound(let database) = ambient else {
            throw SQLiteError.noCurrentDatabase
        }
        return database
    }
}
