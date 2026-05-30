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

extension JSONReader {

    static let trueBytes: [UInt8] = Array("true".utf8)
    static let falseBytes: [UInt8] = Array("false".utf8)
    static let nullBytes: [UInt8] = Array("null".utf8)

    mutating func readTrueLiteral() throws(JSONParseError) -> JSONValue {
        try expectLiteral(Self.trueBytes)
        return .bool(true)
    }

    mutating func readFalseLiteral() throws(JSONParseError) -> JSONValue {
        try expectLiteral(Self.falseBytes)
        return .bool(false)
    }

    mutating func readNullLiteral() throws(JSONParseError) -> JSONValue {
        try expectLiteral(Self.nullBytes)
        return .null
    }

    mutating func expectLiteral(_ literal: [UInt8]) throws(JSONParseError) {
        try requireRemaining(literal.count)
        try matchLiteralBytes(literal)
        position &+= literal.count
    }

    func requireRemaining(_ count: Int) throws(JSONParseError) {
        guard position &+ count <= end else { throw .invalidLiteral(byteOffset: position) }
    }

    func matchLiteralBytes(_ literal: [UInt8]) throws(JSONParseError) {
        for offset in 0 ..< literal.count where bytes[position &+ offset] != literal[offset] {
            throw .invalidLiteral(byteOffset: position)
        }
    }
}
