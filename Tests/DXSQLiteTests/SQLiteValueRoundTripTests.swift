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
import NIOCore

@Suite("DXSQLite value round-trips")
struct SQLiteValueRoundTripTests {

    static let prefix = "dxsqlite-valrt"

    struct CustomerProfile: Codable, Equatable, Sendable {

        struct Address: Codable, Equatable, Sendable {

            let city: String
            let postalCode: String
        }

        let displayName: String
        let loyaltyPoints: Int
        let address: Address
    }

    func makePath() -> String {
        NSTemporaryDirectory() + "\(SQLiteValueRoundTripTests.prefix)-\(UUID().uuidString).sqlite"
    }

    func teardown(_ database: SQLiteDatabase, path: String) async {
        await database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("Int64 boundary values round-trip through INSERT and SELECT as integer")
    func integerBoundariesRoundTrip() async throws {
        let path = makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        try await database.write { writer in
            try writer.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO ledger (id, amount) VALUES (1, ?)", parameters: [.integer(Int64.max)])
            _ = try writer.mutate("INSERT INTO ledger (id, amount) VALUES (2, ?)", parameters: [.integer(Int64.min)])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT amount FROM ledger ORDER BY id")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].value(named: "amount") == .integer(Int64.max))
        #expect(try rows[1].value(named: "amount") == .integer(Int64.min))

        await teardown(database, path: path)
    }

    @Test("a large negative integer round-trips as integer")
    func largeNegativeIntegerRoundTrips() async throws {
        let path = makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let stored: Int64 = -9_007_199_254_740_993
        try await database.write { writer in
            try writer.execute("CREATE TABLE balances (id INTEGER PRIMARY KEY, delta INTEGER NOT NULL)")
            _ = try writer.mutate("INSERT INTO balances (id, delta) VALUES (1, ?)", parameters: [.integer(stored)])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT delta FROM balances WHERE id = 1")
        }
        #expect(rows.count == 1)
        #expect(try rows[0].value(named: "delta") == .integer(stored))

        await teardown(database, path: path)
    }

    @Test("large-magnitude and fractional doubles round-trip as real")
    func doublesRoundTripAsReal() async throws {
        let path = makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let huge = 1.7976931348623157e308
        let fractional = 0.1 + 0.2
        try await database.write { writer in
            try writer.execute("CREATE TABLE measurements (id INTEGER PRIMARY KEY, reading REAL NOT NULL)")
            _ = try writer.mutate("INSERT INTO measurements (id, reading) VALUES (1, ?)", parameters: [.real(huge)])
            _ = try writer.mutate("INSERT INTO measurements (id, reading) VALUES (2, ?)", parameters: [.real(fractional)])
        }

        let rows = try await database.read { reader in
            try reader.query("SELECT reading FROM measurements ORDER BY id")
        }
        #expect(rows.count == 2)
        #expect(try rows[0].value(named: "reading") == .real(huge))
        #expect(try rows[1].value(named: "reading") == .real(fractional))
        #expect(try rows[0].value(named: "reading").type == .real)

        await teardown(database, path: path)
    }

    @Test("the array literal form produces the expected SQLiteValue cases")
    func arrayLiteralProducesExpectedCases() async throws {
        let parameters: [SQLiteValue] = [1, "text", 2.5, true]
        #expect(parameters == [.integer(1), .text("text"), .real(2.5), .integer(1)])

        let mixed: [SQLiteValue] = [-7, "order-42", 3.14, false]
        #expect(mixed == [.integer(-7), .text("order-42"), .real(3.14), .integer(0)])
    }

    @Test("SQLiteValue.json encodes a nested Codable with a unicode field and parses back")
    func jsonEncodesNestedCodableAndParsesBack() async throws {
        let path = makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let profile = CustomerProfile(
            displayName: "Aurélie ✨ Müller",
            loyaltyPoints: 1280,
            address: CustomerProfile.Address(city: "São Paulo", postalCode: "01000-000")
        )
        let encoded = try SQLiteValue.json(profile)
        guard case .text(let jsonString) = encoded else {
            Issue.record("SQLiteValue.json did not produce a text case")
            await teardown(database, path: path)
            return
        }
        #expect(!jsonString.isEmpty)

        try await database.write { writer in
            try writer.execute("CREATE TABLE profiles (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            _ = try writer.mutate("INSERT INTO profiles (id, body) VALUES (1, ?)", parameters: [encoded])
        }

        let storedText = try await database.read { reader in
            try reader.query("SELECT body FROM profiles WHERE id = 1")[0].text(named: "body")
        }
        let parsed = try JSONDecoder().decode(CustomerProfile.self, from: Data(storedText.utf8))
        #expect(parsed == profile)

        await teardown(database, path: path)
    }

    @Test("SQLiteValue(blob:) from a ByteBuffer equals the same bytes and byteBuffer returns them")
    func blobByteBufferRoundTrip() async throws {
        let bytes: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF, 0x10, 0x20]
        let value = SQLiteValue(blob: ByteBuffer(bytes: bytes))
        #expect(value == .blob(bytes))

        var buffer = try value.byteBuffer()
        let readable = buffer.readBytes(length: buffer.readableBytes)
        #expect(readable == bytes)
    }

    @Test("a zero-byte ByteBuffer yields an empty blob")
    func emptyByteBufferYieldsEmptyBlob() async throws {
        let value = SQLiteValue(blob: ByteBuffer(bytes: []))
        #expect(value == .blob([]))

        var buffer = try value.byteBuffer()
        #expect(buffer.readableBytes == 0)
        let readable = buffer.readBytes(length: buffer.readableBytes)
        #expect(readable == [])
    }

    @Test("a blob value persists through INSERT and SELECT with identical bytes")
    func blobPersistsThroughDatabase() async throws {
        let path = makePath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42]
        let value = SQLiteValue(blob: ByteBuffer(bytes: payload))
        try await database.write { writer in
            try writer.execute("CREATE TABLE attachments (id INTEGER PRIMARY KEY, content BLOB NOT NULL)")
            _ = try writer.mutate("INSERT INTO attachments (id, content) VALUES (1, ?)", parameters: [value])
        }

        let row = try await database.read { reader in
            try reader.query("SELECT content FROM attachments WHERE id = 1")[0]
        }
        #expect(try row.value(named: "content") == .blob(payload))
        #expect(try row.blob(named: "content") == payload)

        await teardown(database, path: path)
    }

    @Test("byteBuffer on a non-blob value throws valueTypeMismatch")
    func byteBufferOnNonBlobThrows() async throws {
        let value = SQLiteValue.integer(99)
        #expect(throws: SQLiteError.self) {
            _ = try value.byteBuffer()
        }
        do {
            _ = try value.byteBuffer()
            Issue.record("byteBuffer on an integer value did not throw")
        } catch {
            #expect(error == SQLiteError.valueTypeMismatch(expected: .blob, actual: .integer))
        }
    }
}
