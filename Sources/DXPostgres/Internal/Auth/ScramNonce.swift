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

// Generates the client nonce for a SCRAM exchange: 18 random bytes rendered as
// base64. The base64 alphabet contains no comma, so the result is always a valid
// SCRAM printable token, and 18 bytes (144 bits) of entropy comfortably exceeds
// the protocol's freshness requirement.
enum ScramNonce {

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 18)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Base64.encode(bytes)
    }
}
