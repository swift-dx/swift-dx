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

// Server-side error notification. Linked-list shape: each packet may
// reference a nested cause via the has_nested flag. Wire layout per node:
//   Int32 (LE) code
//   String     name
//   String     message
//   String     stack_trace
//   Bool       has_nested
//   if has_nested: another full Exception node
//
// Recursion through a nested class wrapper keeps the type a value type
// while still allowing the self-reference. The maxNestingDepth guard
// bounds DoS exposure from a hostile peer that chains exception nodes
// to drive the decoder into stack exhaustion.
struct ClickHouseServerExceptionPacket: Sendable, Equatable {

    static let maxNestingDepth = 32

    let code: Int32
    let name: String
    let message: String
    let stackTrace: String
    let nested: NestedException

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseFixedWidthInteger(code)
        buffer.writeClickHouseString(name)
        buffer.writeClickHouseString(message)
        buffer.writeClickHouseString(stackTrace)
        switch nested {
        case .none:
            buffer.writeClickHouseBool(false)
        case .some(let node):
            buffer.writeClickHouseBool(true)
            node.value.encode(into: &buffer)
        }
    }

    static func decode(from buffer: inout ByteBuffer) throws -> Self {
        try decode(from: &buffer, depth: 0)
    }

    private static func decode(from buffer: inout ByteBuffer, depth: Int) throws -> Self {
        guard depth <= maxNestingDepth else {
            throw ClickHouseError.exceptionNestingTooDeep(maxDepth: maxNestingDepth)
        }
        let code = try buffer.readClickHouseFixedWidthInteger(Int32.self)
        let name = try buffer.readClickHouseString()
        let message = try buffer.readClickHouseString()
        let stackTrace = try buffer.readClickHouseString()
        let hasNested = try buffer.readClickHouseBool()
        let nested: NestedException
        if hasNested {
            nested = .some(NestedException.Node(try Self.decode(from: &buffer, depth: depth + 1)))
        } else {
            nested = .none
        }
        return .init(code: code, name: name, message: message, stackTrace: stackTrace, nested: nested)
    }

    // Linked-list tail of a chained server exception. `.none` is the
    // terminator; `.some(Node)` holds the next exception in the chain.
    enum NestedException: Sendable, Equatable {

        case none
        case some(Node)

        final class Node: @unchecked Sendable, Equatable {

            let value: ClickHouseServerExceptionPacket

            init(_ value: ClickHouseServerExceptionPacket) {
                self.value = value
            }

            static func == (lhs: Node, rhs: Node) -> Bool {
                lhs.value == rhs.value
            }

        }

    }

    func toPublic() -> ClickHouseError.ServerException {
        var nestedMessages: [String] = []
        var current = nested
        loop: while true {
            switch current {
            case .none: break loop
            case .some(let node):
                nestedMessages.append(node.value.message)
                current = node.value.nested
            }
        }
        return ClickHouseError.ServerException(
            code: code,
            name: name,
            message: message,
            stackTrace: stackTrace,
            nestedMessages: nestedMessages
        )
    }

}
