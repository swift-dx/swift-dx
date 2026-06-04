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

import Crypto

// PBKDF2-HMAC-SHA256 reduced to the single case SCRAM needs: a derived key
// exactly one hash block (32 bytes) long. This is SCRAM's `Hi(str, salt, i)`
// function — the salt is followed by the big-endian block index 1, then the HMAC
// is folded over itself `iterations` times, XOR-accumulating each round. Used
// only during the connection handshake, not on any request hot path.
enum PostgresPBKDF2 {

    static func deriveSHA256(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var previous = mac(key: key, message: salt + [0, 0, 0, 1])
        var result = previous
        for _ in 1..<iterations {
            previous = mac(key: key, message: previous)
            xor(&result, with: previous)
        }
        return result
    }

    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        mac(key: SymmetricKey(data: key), message: message)
    }

    private static func mac(key: SymmetricKey, message: [UInt8]) -> [UInt8] {
        var authentication = HMAC<SHA256>(key: key)
        authentication.update(data: message)
        return Array(authentication.finalize())
    }

    private static func xor(_ target: inout [UInt8], with other: [UInt8]) {
        for index in target.indices {
            target[index] ^= other[index]
        }
    }
}
