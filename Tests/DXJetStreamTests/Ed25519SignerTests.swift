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
import Testing
@testable import DXJetStream

@Suite
struct Ed25519SignerTests {

    @Test
    func ed25519Signer_signaturesValidateWithPublicKey() throws {
        let rawSeed = TestFixtures.randomSeedBytes()
        let seed = NKeySeed(rawSeed: rawSeed)
        let signer = try Ed25519Signer(seed: seed)
        let signatureBase64 = try signer.sign(nonce: "abc-xyz-nonce-1234567890")
        let signatureBytes = try Base64.decode(signatureBase64)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed)
        let publicKey = privateKey.publicKey
        let valid = publicKey.isValidSignature(signatureBytes, for: Array("abc-xyz-nonce-1234567890".utf8))
        #expect(valid)
    }

    @Test
    func ed25519Signer_repeatedSignaturesAllValidate() throws {
        let rawSeed = TestFixtures.randomSeedBytes()
        let seed = NKeySeed(rawSeed: rawSeed)
        let signer = try Ed25519Signer(seed: seed)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed).publicKey
        let nonce = "repeat-test"
        for _ in 0..<4 {
            let signatureBase64 = try signer.sign(nonce: nonce)
            let signatureBytes = try Base64.decode(signatureBase64)
            #expect(publicKey.isValidSignature(signatureBytes, for: Array(nonce.utf8)))
        }
    }

    @Test
    func ed25519Signer_emitsBase64UrlEncoding() throws {
        let seed = NKeySeed(rawSeed: TestFixtures.randomSeedBytes())
        let signer = try Ed25519Signer(seed: seed)
        let signature = try signer.sign(nonce: "test")
        #expect(!signature.contains("+"))
        #expect(!signature.contains("/"))
        #expect(!signature.contains("="))
    }
}
