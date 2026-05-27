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
import DXCore

struct Ed25519Signer: Sendable {

    private let rawSeed: [UInt8]

    init(seed: NKeySeed) throws(JetStreamError) {
        do {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: seed.rawSeed)
        } catch {
            throw JetStreamError.credentialsSeedInvalid(reason: "ed25519 key construction failed")
        }
        self.rawSeed = seed.rawSeed
    }

    func sign(nonce: String) throws(JetStreamError) -> String {
        let payload = Array(nonce.utf8)
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed)
            let signature = try privateKey.signature(for: payload)
            return Base64URL.encode(Array(signature))
        } catch {
            throw JetStreamError.credentialsSignatureFailed(reason: "ed25519 signing failed")
        }
    }
}
