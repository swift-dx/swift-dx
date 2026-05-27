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

import Foundation
@testable import DXJetStream

enum TestFixtures {

    static func randomSeedBytes() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return bytes
    }

    static func encodedSeed() throws -> String {
        try NKeySeed.encode(rawSeed: randomSeedBytes())
    }

    static func credentialsFile(jwt: String = "test.jwt.payload", encodedSeed: String) -> String {
        """
        -----BEGIN NATS USER JWT-----
        \(jwt)
        ------END NATS USER JWT------

        -----BEGIN USER NKEY SEED-----
        \(encodedSeed)
        ------END USER NKEY SEED------
        """
    }
}
