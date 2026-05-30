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

@testable import DXClickHouse
import NIOCore
import Testing

@Suite("ClickHouse server exception packet")
struct ClickHouseServerExceptionPacketTests {

    @Test("flat exception (no nested) round-trips faithfully")
    func flatExceptionRoundTrip() throws {
        let original = ClickHouseServerExceptionPacket(
            code: 81,
            name: "DB::Exception",
            message: "Database missing",
            stackTrace: "at SomeFunction()\nat OtherFunction()",
            nested: .none
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        let decoded = try ClickHouseServerExceptionPacket.decode(from: &buffer)
        #expect(decoded == original)
        #expect(buffer.readableBytes == 0)
    }

    @Test("nested exception round-trips and preserves the chain")
    func nestedExceptionRoundTrip() throws {
        let cause = ClickHouseServerExceptionPacket(
            code: 999,
            name: "DB::IOException",
            message: "disk full",
            stackTrace: "",
            nested: .none
        )
        let original = ClickHouseServerExceptionPacket(
            code: 81,
            name: "DB::Exception",
            message: "could not write",
            stackTrace: "frame 1\nframe 2",
            nested: .some(.init(cause))
        )
        var buffer = ByteBuffer()
        original.encode(into: &buffer)

        let decoded = try ClickHouseServerExceptionPacket.decode(from: &buffer)
        #expect(decoded.code == 81)
        #expect(decoded.message == "could not write")
        guard case .some(let node) = decoded.nested else {
            Issue.record("expected a nested cause; got .none")
            return
        }
        #expect(node.value.code == 999)
        #expect(node.value.message == "disk full")
        #expect(node.value.nested == .none)
    }

    @Test("a chain at exactly the depth limit decodes; one beyond throws")
    func depthLimitEnforced() throws {
        // Build the deepest chain that decode() still accepts. The depth
        // counter starts at 0 for the outermost node and increments per
        // nested layer; the legal range is 0...maxNestingDepth, so the
        // longest legal chain has maxNestingDepth + 1 nodes.
        var leaf = ClickHouseServerExceptionPacket(
            code: 0, name: "leaf", message: "", stackTrace: "", nested: .none
        )
        for index in 1...ClickHouseServerExceptionPacket.maxNestingDepth {
            leaf = ClickHouseServerExceptionPacket(
                code: Int32(index),
                name: "level-\(index)",
                message: "",
                stackTrace: "",
                nested: .some(.init(leaf))
            )
        }
        var buffer = ByteBuffer()
        leaf.encode(into: &buffer)
        let decoded = try ClickHouseServerExceptionPacket.decode(from: &buffer)
        #expect(decoded.code > 0)

        // Wrapping once more pushes decode depth to maxNestingDepth + 1
        // and the limit kicks in.
        let overflow = ClickHouseServerExceptionPacket(
            code: -1,
            name: "extra",
            message: "",
            stackTrace: "",
            nested: .some(.init(leaf))
        )
        var overflowBuffer = ByteBuffer()
        overflow.encode(into: &overflowBuffer)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseServerExceptionPacket.decode(from: &overflowBuffer)
        }
    }

    @Test("Equatable considers two equally-nested exceptions equal")
    func equatableHonorsNesting() {
        let a = ClickHouseServerExceptionPacket(
            code: 1, name: "n", message: "m", stackTrace: "s",
            nested: .some(.init(.init(code: 2, name: "n2", message: "m2", stackTrace: "s2", nested: .none)))
        )
        let b = ClickHouseServerExceptionPacket(
            code: 1, name: "n", message: "m", stackTrace: "s",
            nested: .some(.init(.init(code: 2, name: "n2", message: "m2", stackTrace: "s2", nested: .none)))
        )
        #expect(a == b)
    }

}
