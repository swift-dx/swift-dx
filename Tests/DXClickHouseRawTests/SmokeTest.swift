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

import DXClickHouseRaw
import Foundation
import Testing

@Suite(
    "DXClickHouseRaw smoke",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct RawClickHouseSmoke {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var user: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
    }

    private static var password: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
    }

    private static var database: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "default"
    }

    @Test("SELECT 1 round-trips through the raw POSIX transport")
    func selectOne() throws {
        let connection = try RawClickHouseConnection(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
        defer { connection.close() }
        #expect(connection.serverInfo.revision >= 54_400)
        try connection.sendQuery("SELECT 1")
        var capturedValue: UInt8 = 0
        let rows = try connection.receiveBlocks { block, body in
            #expect(block.rowCount == 1)
            #expect(block.columnCount == 1)
            #expect(block.columnTypes.first == "UInt8")
            #expect(body.count == 1)
            capturedValue = body.load(as: UInt8.self)
        }
        #expect(rows == 1)
        #expect(capturedValue == 1)
    }

    @Test("SELECT toUInt32(123) round-trips a 4-byte fixed-width column")
    func selectUInt32() throws {
        let connection = try RawClickHouseConnection(
            host: Self.host,
            port: Self.port,
            user: Self.user,
            password: Self.password,
            database: Self.database
        )
        defer { connection.close() }
        try connection.sendQuery("SELECT toUInt32(123)")
        var captured: UInt32 = 0
        let rows = try connection.receiveBlocks { block, body in
            #expect(block.columnTypes.first == "UInt32")
            var storage: UInt32 = 0
            withUnsafeMutableBytes(of: &storage) { destination in
                destination.copyMemory(from: body)
            }
            captured = UInt32(littleEndian: storage)
        }
        #expect(rows == 1)
        #expect(captured == 123)
    }
}
