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

// The server-first SCRAM message: the combined nonce ('r'), the base64-encoded
// salt ('s'), and the iteration count ('i'). A missing or malformed field is an
// authentication failure, surfaced with the specific attribute that was wrong.
struct ScramServerFirst: Equatable {

    let nonce: String
    let salt: [UInt8]
    let iterations: Int

    static func parse(_ data: [UInt8]) throws(PostgresError) -> ScramServerFirst {
        let attributes = ScramAttributes.parse(String(decoding: data, as: UTF8.self))
        let nonce = try value(attributes, key: "r")
        let salt = try decodeSalt(try value(attributes, key: "s"))
        let iterations = try parseIterations(try value(attributes, key: "i"))
        return ScramServerFirst(nonce: nonce, salt: salt, iterations: iterations)
    }

    private static func value(_ attributes: [String: String], key: String) throws(PostgresError) -> String {
        guard let value = attributes[key] else {
            throw PostgresError.authenticationFailed(reason: "SCRAM server-first message missing '\(key)' attribute")
        }
        return value
    }

    private static func decodeSalt(_ text: String) throws(PostgresError) -> [UInt8] {
        do {
            return try Base64.decode(text)
        } catch {
            throw PostgresError.authenticationFailed(reason: "SCRAM salt is not valid base64")
        }
    }

    private static func parseIterations(_ text: String) throws(PostgresError) -> Int {
        guard let iterations = Int(text), iterations > 0 else {
            throw PostgresError.authenticationFailed(reason: "SCRAM iteration count is invalid: \(text)")
        }
        return iterations
    }
}
