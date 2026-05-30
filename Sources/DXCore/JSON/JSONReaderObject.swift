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

    mutating func readObject() throws(JSONParseError) -> JSONValue {
        try enterDepth()
        position &+= 1
        let object = try readObjectBody()
        depth &-= 1
        return .object(object)
    }

    mutating func readObjectBody() throws(JSONParseError) -> JSONObject {
        skipWhitespace()
        if try consumeClosingIfPresent(Ascii.braceClose) { return JSONObject(members: []) }
        var members: [JSONObject.Member] = []
        members.reserveCapacity(JSONReader.containerCapacityHint)
        try readObjectMembers(into: &members)
        return JSONObject(members: members)
    }

    mutating func readObjectMembers(into members: inout [JSONObject.Member]) throws(JSONParseError) {
        while true {
            try readOneMember(into: &members)
            let separator = try readSeparator(closing: Ascii.braceClose)
            if case .end = separator { return }
        }
    }

    mutating func readOneMember(into members: inout [JSONObject.Member]) throws(JSONParseError) {
        skipWhitespace()
        let key = try readObjectKey()
        try expectColon()
        let value = try parseValue()
        try appendMember(key: key, value: value, into: &members)
    }

    mutating func readObjectKey() throws(JSONParseError) -> JSONString {
        let byte = try currentByte()
        guard byte == Ascii.quote else { throw .unexpectedByte(byteOffset: position, found: byte) }
        return try readStringToken()
    }

    mutating func expectColon() throws(JSONParseError) {
        skipWhitespace()
        let byte = try currentByte()
        try requireByte(byte, equals: Ascii.colon)
        position &+= 1
    }

    func requireByte(_ byte: UInt8, equals expected: UInt8) throws(JSONParseError) {
        guard byte == expected else { throw .unexpectedByte(byteOffset: position, found: byte) }
    }

    mutating func appendMember(key: JSONString, value: JSONValue, into members: inout [JSONObject.Member]) throws(JSONParseError) {
        switch indexOfKey(key, in: members) {
        case .found(let index): try replaceOrReject(key: key, value: value, at: index, into: &members)
        case .notFound: members.append(JSONObject.Member(key: key, value: value))
        }
    }

    func indexOfKey(_ key: JSONString, in members: [JSONObject.Member]) -> Lookup<Int> {
        for index in members.indices where members[index].key == key {
            return .found(index)
        }
        return .notFound
    }

    mutating func replaceOrReject(key: JSONString, value: JSONValue, at index: Int, into members: inout [JSONObject.Member]) throws(JSONParseError) {
        guard limits.duplicateKeys == .lastValueWins else { throw .duplicateKey(byteOffset: position, key: key.value) }
        members[index] = JSONObject.Member(key: key, value: value)
    }

    mutating func readArray() throws(JSONParseError) -> JSONValue {
        try enterDepth()
        position &+= 1
        let elements = try readArrayBody()
        depth &-= 1
        return .array(elements)
    }

    mutating func readArrayBody() throws(JSONParseError) -> [JSONValue] {
        skipWhitespace()
        if try consumeClosingIfPresent(Ascii.bracketClose) { return [] }
        var elements: [JSONValue] = []
        elements.reserveCapacity(JSONReader.containerCapacityHint)
        try readArrayElements(into: &elements)
        return elements
    }

    mutating func readArrayElements(into elements: inout [JSONValue]) throws(JSONParseError) {
        while true {
            elements.append(try parseValue())
            let separator = try readSeparator(closing: Ascii.bracketClose)
            if case .end = separator { return }
        }
    }
}
