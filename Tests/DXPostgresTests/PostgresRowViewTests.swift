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

@Suite struct PostgresRowViewTests {

    private func dataRowBuffer(_ values: [String]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeInteger(UInt8(0x44))
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(Int16(values.count))
        for value in values {
            let bytes = Array(value.utf8)
            buffer.writeInteger(Int32(bytes.count))
            buffer.writeBytes(bytes)
        }
        return buffer
    }

    @Test func readsFieldsByIndex() throws {
        let row = PostgresRowView(buffer: dataRowBuffer(["ab", "cd"]), base: 0)
        #expect(row.fieldCount == 2)
        #expect(try row.text(0) == "ab")
        #expect(try row.text(1) == "cd")
    }

    @Test func columnIndexBeyondFieldCountThrowsOutOfRange() throws {
        let row = PostgresRowView(buffer: dataRowBuffer(["ab", "cd"]), base: 0)
        do {
            _ = try row.text(2)
            Issue.record("expected an out-of-range error for column index 2")
        } catch let error as PostgresError {
            guard case .columnIndexOutOfRange(let index, let columnCount) = error else {
                Issue.record("expected columnIndexOutOfRange, got \(error)")
                return
            }
            #expect(index == 2)
            #expect(columnCount == 2)
        }
    }

    @Test func negativeColumnIndexThrowsOutOfRange() throws {
        let row = PostgresRowView(buffer: dataRowBuffer(["ab"]), base: 0)
        #expect(throws: PostgresError.self) {
            _ = try row.bytes(-1)
        }
    }

    @Test func parsesDecimalIntegersInPlace() throws {
        let row = PostgresRowView(buffer: dataRowBuffer(["0", "-42", "-9223372036854775808", "9223372036854775807"]), base: 0)
        #expect(try row.int64(0) == 0)
        #expect(try row.int64(1) == -42)
        #expect(try row.int64(2) == Int64.min)
        #expect(try row.int64(3) == Int64.max)
    }
}
