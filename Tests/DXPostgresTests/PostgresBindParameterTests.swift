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
import Glibc
@testable import DXPostgres

@Suite struct PostgresBindParameterTests {

    @Test func bindEncodesParameterCountAboveSignedInt16WithoutTrapping() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1 << 20)
        let parameters = Array(repeating: PostgresCell.sqlNull, count: 40000)
        FrontendMessage.appendBindTextResult(into: &buffer, statementName: "", parameters: parameters)
        #expect(buffer.getInteger(at: 11, as: Int16.self) == Int16(bitPattern: UInt16(40000)))
    }

    @Test func queryRejectsMoreParametersThanTheWireLimit() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer { close(descriptors[1]) }
        let connection = BlockingPostgresConnection(descriptor: descriptors[0])
        defer { connection.close() }

        let bindings = Array(repeating: PostgresCell.bytes([0x31]), count: 70000)
        do {
            _ = try connection.query("SELECT 1", bindings: bindings) { _ in }
            Issue.record("expected a parameter-count error above the wire limit")
        } catch let error as PostgresError {
            guard case .parameterCountMismatch = error else {
                Issue.record("expected parameterCountMismatch, got \(error)")
                return
            }
        }
    }
}
