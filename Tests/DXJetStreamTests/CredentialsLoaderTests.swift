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
import Testing
@testable import DXJetStream

@Suite
struct CredentialsLoaderTests {

    private func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    @Test
    func credentialsLoader_resolvesAnonymousToAnonymous() throws {
        let resolved = try CredentialsLoader.resolve(.anonymous)
        if case .anonymous = resolved {} else {
            Issue.record("Expected .anonymous")
        }
    }

    @Test
    func credentialsLoader_resolvesLiteralToAuthenticated() throws {
        let seed = try TestFixtures.encodedSeed()
        let credentials = NatsCredentials(jwt: "test.jwt.payload", seed: seed)
        let resolved = try CredentialsLoader.resolve(.literal(credentials))
        if case .authenticated(let jwt, _) = resolved {
            #expect(jwt == credentials.jwt)
        } else {
            Issue.record("Expected .authenticated")
        }
    }

    @Test
    func credentialsLoader_resolvesBase64String() throws {
        let seed = try TestFixtures.encodedSeed()
        let credsFile = TestFixtures.credentialsFile(jwt: "test.jwt.payload", encodedSeed: seed)
        let encoded = base64Encode(credsFile)
        let resolved = try CredentialsLoader.resolve(.base64String(encoded))
        if case .authenticated(let jwt, _) = resolved {
            #expect(jwt == "test.jwt.payload")
        } else {
            Issue.record("Expected .authenticated")
        }
    }

    @Test
    func credentialsLoader_throwsWhenEnvironmentVariableMissing() {
        #expect(throws: JetStreamError.credentialsEnvironmentMissing(variable: "SWIFTDX_TEST_UNSET_XYZ")) {
            _ = try CredentialsLoader.resolve(.base64Environment(variable: "SWIFTDX_TEST_UNSET_XYZ"))
        }
    }

    @Test
    func credentialsLoader_throwsOnInvalidBase64() {
        #expect(throws: JetStreamError.self) {
            _ = try CredentialsLoader.resolve(.base64String("@@@@not-base64@@@@"))
        }
    }

    @Test
    func credentialsLoader_throwsOnMissingJwtBlock() throws {
        let seed = try TestFixtures.encodedSeed()
        let raw = """
        -----BEGIN USER NKEY SEED-----
        \(seed)
        ------END USER NKEY SEED------
        """
        let encoded = base64Encode(raw)
        #expect(throws: JetStreamError.credentialsJwtMissing) {
            _ = try CredentialsLoader.resolve(.base64String(encoded))
        }
    }
}
