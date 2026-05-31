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

@Suite("DXSQLite Codable decoding coverage")
struct SQLiteCodableCoverageTests {

    struct Inner: Codable, Equatable {

        let value: Int
        let name: String
    }

    struct WideRecord: Codable, Equatable {

        let flag: Bool
        let label: String
        let ratio: Double
        let fraction: Float
        let whole: Int
        let small: Int8
        let medium: Int16
        let large: Int32
        let huge: Int64
        let unsignedWhole: UInt
        let unsignedSmall: UInt8
        let unsignedMedium: UInt16
        let unsignedLarge: UInt32
        let unsignedHuge: UInt64
        let nested: Inner
    }

    struct NarrowRecord: Decodable, Equatable {

        let small: Int8
    }

    struct Wrapper: Decodable {

        let nested: Inner
    }

    struct NilProbe: Decodable, Equatable {

        let present: Bool

        enum CodingKeys: String, CodingKey {

            case maybe
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            present = !(try container.decodeNil(forKey: .maybe))
        }
    }

    struct WantsUnkeyed: Decodable {

        init(from decoder: Decoder) throws {
            _ = try decoder.unkeyedContainer()
        }
    }

    struct WantsSingleValue: Decodable {

        init(from decoder: Decoder) throws {
            _ = try decoder.singleValueContainer()
        }
    }

    struct WantsNestedKeyed: Decodable {

        enum CodingKeys: String, CodingKey {

            case anchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .anchor)
        }
    }

    struct WantsNestedUnkeyed: Decodable {

        enum CodingKeys: String, CodingKey {

            case anchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.nestedUnkeyedContainer(forKey: .anchor)
        }
    }

    struct WantsSuper: Decodable {

        enum CodingKeys: String, CodingKey {

            case anchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.superDecoder()
        }
    }

    struct WantsSuperForKey: Decodable {

        enum CodingKeys: String, CodingKey {

            case anchor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.superDecoder(forKey: .anchor)
        }
    }

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "dxsqlite-codable-\(UUID().uuidString).sqlite"
    }

    static func removeDatabase(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test("every scalar width and a nested JSON value decode through one row")
    func everyScalarWidthDecodes() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let records = try await database.read { reader in
            try reader.query(
                """
                SELECT 1 AS flag, 'hello' AS label, 2.5 AS ratio, 1.25 AS fraction,
                       7 AS whole, 8 AS small, 16 AS medium, 32 AS large, 64 AS huge,
                       70 AS unsignedWhole, 80 AS unsignedSmall, 160 AS unsignedMedium,
                       320 AS unsignedLarge, 640 AS unsignedHuge,
                       '{"value":99,"name":"deep"}' AS nested
                """,
                as: WideRecord.self
            )
        }
        let expected = WideRecord(
            flag: true, label: "hello", ratio: 2.5, fraction: 1.25,
            whole: 7, small: 8, medium: 16, large: 32, huge: 64,
            unsignedWhole: 70, unsignedSmall: 80, unsignedMedium: 160,
            unsignedLarge: 320, unsignedHuge: 640,
            nested: Inner(value: 99, name: "deep")
        )
        #expect(records == [expected])

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("an integer that overflows the target width throws decodingFailed")
    func overflowingIntegerThrows() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT 9999 AS small", as: NarrowRecord.self)
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("decodeNil reports null, non-null, and absent columns correctly")
    func decodeNilBranches() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        let nullProbe = try await database.read { reader in
            try reader.query("SELECT NULL AS maybe", as: NilProbe.self)
        }
        #expect(nullProbe.count == 1)
        #expect(nullProbe[0].present == false)

        let presentProbe = try await database.read { reader in
            try reader.query("SELECT 5 AS maybe", as: NilProbe.self)
        }
        #expect(presentProbe[0].present == true)

        let absentProbe = try await database.read { reader in
            try reader.query("SELECT 1 AS other", as: NilProbe.self)
        }
        #expect(absentProbe[0].present == false)

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("container shapes a flat row cannot provide all throw")
    func unsupportedContainerShapesThrow() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsUnkeyed.self) }
        }
        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsSingleValue.self) }
        }
        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsNestedKeyed.self) }
        }
        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsNestedUnkeyed.self) }
        }
        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsSuper.self) }
        }
        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { try $0.query("SELECT 1 AS anchor", as: WantsSuperForKey.self) }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }

    @Test("a malformed nested JSON value throws decodingFailed")
    func malformedNestedJSONThrows() async throws {
        let path = Self.temporaryPath()
        let database = try await SQLite.connect(SQLiteConfiguration(location: .file(path: path)))

        await #expect(throws: SQLiteError.self) {
            _ = try await database.read { reader in
                try reader.query("SELECT 'not valid json' AS nested", as: Wrapper.self)
            }
        }

        await database.close()
        Self.removeDatabase(at: path)
    }
}
