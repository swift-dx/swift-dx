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

import Testing
import NIOCore
@testable import DXPostgres

@Suite struct FrontendMessageTests {

    @Test func encodesInt64ParametersAsDecimalText() {
        #expect(boundInt64Text(0) == "0")
        #expect(boundInt64Text(7) == "7")
        #expect(boundInt64Text(42) == "42")
        #expect(boundInt64Text(-1) == "-1")
        #expect(boundInt64Text(-9000000000) == "-9000000000")
        #expect(boundInt64Text(Int64.min) == "-9223372036854775808")
        #expect(boundInt64Text(Int64.max) == "9223372036854775807")
    }

    @Test func startupMessageCarriesProtocolAndParameters() {
        let buffer = FrontendMessage.startup(user: "alice", database: "appdb", applicationName: "myapp", allocator: ByteBufferAllocator())
        #expect(Int(buffer.getInteger(at: 0, as: Int32.self) ?? 0) == buffer.readableBytes)
        #expect(buffer.getInteger(at: 4, as: Int32.self) == 196608)
        let parameters = String(decoding: buffer.getBytes(at: 8, length: buffer.readableBytes - 8) ?? [], as: UTF8.self)
        #expect(parameters.contains("user"))
        #expect(parameters.contains("alice"))
        #expect(parameters.contains("database"))
        #expect(parameters.contains("appdb"))
        #expect(parameters.contains("application_name"))
        #expect(parameters.contains("client_encoding"))
    }

    // appendBindInt64 writes: tag(1) length(4) portal-cstring("")(1) statement-cstring("")(1)
    // param-format-count(2) text-format-code(2) param-count(2) param-length(4) then the digits.
    private func boundInt64Text(_ value: Int64) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        FrontendMessage.appendBindInt64(into: &buffer, statementName: "", value: value)
        let length = Int(buffer.getInteger(at: 13, as: Int32.self) ?? -1)
        return String(decoding: buffer.getBytes(at: 17, length: length) ?? [], as: UTF8.self)
    }
}
