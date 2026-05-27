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

import DXCore

enum PublishAckParser {

    static func parse(_ payload: [UInt8]) throws(JetStreamError) -> PublishAck {
        guard payload.count > 2 else {
            throw JetStreamError.publishAckError(reason: "payload too short")
        }
        return try execute {
            try payload.withUnsafeBufferPointer { bytes in
                if case .found = findKey(bytes, key: errorKey) {
                    throw JetStreamError.publishAckError(reason: "server reported error")
                }
                var sequence: UInt64 = 0
                if case .found(let startIndex) = findKey(bytes, key: sequenceKey) {
                    var i = startIndex
                    while i < bytes.count, bytes[i] >= Ascii.digitZero, bytes[i] <= Ascii.digitNine {
                        sequence = sequence &* Radix.decimal &+ UInt64(bytes[i] - Ascii.digitZero)
                        i &+= 1
                    }
                }
                let duplicate: Bool
                switch findKey(bytes, key: duplicateKey) {
                case .found: duplicate = true
                case .notFound: duplicate = false
                }
                return PublishAck(stream: "", sequence: sequence, duplicate: duplicate)
            }
        }
    }

    private enum KeyLocation: Sendable, Equatable {
        case found(afterIndex: Int)
        case notFound
    }

    private static let errorKey: [UInt8] = Array("\"error\"".utf8)
    private static let sequenceKey: [UInt8] = Array("\"seq\":".utf8)
    private static let duplicateKey: [UInt8] = Array("\"duplicate\":true".utf8)

    @inline(__always)
    private static func findKey(_ bytes: UnsafeBufferPointer<UInt8>, key: [UInt8]) -> KeyLocation {
        let kCount = key.count
        guard bytes.count >= kCount else { return .notFound }
        return scanForKey(bytes: bytes, key: key, limit: bytes.count - kCount, kCount: kCount)
    }

    @inline(__always)
    private static func scanForKey(bytes: UnsafeBufferPointer<UInt8>, key: [UInt8], limit: Int, kCount: Int) -> KeyLocation {
        var index = 0
        while index <= limit {
            if keyMatches(bytes: bytes, at: index, key: key, kCount: kCount) {
                return .found(afterIndex: index + kCount)
            }
            index &+= 1
        }
        return .notFound
    }

    @inline(__always)
    private static func keyMatches(bytes: UnsafeBufferPointer<UInt8>, at offset: Int, key: [UInt8], kCount: Int) -> Bool {
        for position in 0..<kCount where bytes[offset + position] != key[position] {
            return false
        }
        return true
    }
}
