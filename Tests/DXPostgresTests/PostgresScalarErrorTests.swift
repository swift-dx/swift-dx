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
import Glibc
@testable import DXPostgres

@Suite struct PostgresScalarErrorTests {

    @Test func scalarFastPathSurfacesServerErrorRatherThanReturningZero() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        let clientDescriptor = descriptors[0]
        let serverDescriptor = descriptors[1]
        defer { close(serverDescriptor) }

        let serverResponse = errorResponse(severity: "ERROR", sqlState: "22012", message: "division by zero") + readyForQuery
        serverResponse.withUnsafeBytes { raw in
            _ = write(serverDescriptor, raw.baseAddress, raw.count)
        }

        let connection = BlockingPostgresConnection(descriptor: clientDescriptor)
        defer { connection.close() }
        #expect(throws: PostgresError.self) {
            _ = try connection.queryScalarInt64Inline("SELECT $1::int8", value: 1)
        }
    }

    private func errorResponse(severity: String, sqlState: String, message: String) -> [UInt8] {
        var body: [UInt8] = []
        body.append(contentsOf: field(0x53, severity))
        body.append(contentsOf: field(0x43, sqlState))
        body.append(contentsOf: field(0x4D, message))
        body.append(0)
        return [0x45] + bigEndianInt32(Int32(body.count + 4)) + body
    }

    private func field(_ code: UInt8, _ value: String) -> [UInt8] {
        [code] + Array(value.utf8) + [0]
    }

    private var readyForQuery: [UInt8] {
        [0x5A] + bigEndianInt32(5) + [0x49]
    }

    private func bigEndianInt32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
    }
}
