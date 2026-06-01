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

import NIOCore
import Testing

@testable import DXPostgres

@Suite struct FrontendMessageTests {

    @Test func startupMessageCarriesLengthAndParameters() {
        let buffer = FrontendMessage.startup(user: "ada", database: "appdb", applicationName: "swift-dx", allocator: ByteBufferAllocator())
        var reading = buffer
        let length = reading.readInteger(as: Int32.self)
        #expect(length == Int32(buffer.readableBytes))
        #expect(reading.readInteger(as: Int32.self) == FrontendMessage.protocolVersion)
        let remainder = reading.readString(length: reading.readableBytes) ?? ""
        #expect(remainder.contains("user"))
        #expect(remainder.contains("ada"))
        #expect(remainder.contains("appdb"))
    }

    @Test func queryMessageHasTagLengthAndNullTerminatedSql() {
        let buffer = FrontendMessage.query("SELECT 1", allocator: ByteBufferAllocator())
        var reading = buffer
        #expect(reading.readInteger(as: UInt8.self) == 0x51)
        let length = reading.readInteger(as: Int32.self) ?? 0
        #expect(Int(length) == buffer.readableBytes - 1)
        let sql = reading.readString(length: reading.readableBytes) ?? ""
        #expect(sql == "SELECT 1\u{0}")
    }

    @Test func sslRequestIsEightBytesWithMagicCode() {
        let buffer = FrontendMessage.sslRequest(allocator: ByteBufferAllocator())
        var reading = buffer
        #expect(buffer.readableBytes == 8)
        #expect(reading.readInteger(as: Int32.self) == 8)
        #expect(reading.readInteger(as: Int32.self) == FrontendMessage.sslRequestCode)
    }

    @Test func bindSendsTextParametersAndNullLengthForSqlNull() {
        let buffer = FrontendMessage.bind(portalName: "", statementName: "", parameters: [.bytes(Array("hi".utf8)), .sqlNull], allocator: ByteBufferAllocator())
        var reading = buffer
        #expect(reading.readInteger(as: UInt8.self) == 0x42)
        let length = reading.readInteger(as: Int32.self) ?? 0
        #expect(Int(length) == buffer.readableBytes - 1)
    }
}
