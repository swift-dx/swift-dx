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
struct CredentialsLoaderBase64StringTests {

    @Test
    func resolve_base64String_decodesAndReturnsAuthenticated() throws {
        let seed = try TestFixtures.encodedSeed()
        let credsContent = TestFixtures.credentialsFile(jwt: "fixture.jwt", encodedSeed: seed)
        guard let credsData = credsContent.data(using: .utf8) else {
            Issue.record("expected UTF-8 encoding to succeed")
            return
        }
        let base64 = credsData.base64EncodedString()
        let resolved = try CredentialsLoader.resolve(.base64String(base64))
        switch resolved {
        case .authenticated(let jwt, _): #expect(jwt == "fixture.jwt")
        case .anonymous: Issue.record("expected authenticated credentials from base64String input")
        }
    }

    @Test
    func resolve_base64Environment_readsFromEnvAndAuthenticates() throws {
        let seed = try TestFixtures.encodedSeed()
        let credsContent = TestFixtures.credentialsFile(jwt: "env.jwt", encodedSeed: seed)
        guard let credsData = credsContent.data(using: .utf8) else {
            Issue.record("expected UTF-8 encoding to succeed")
            return
        }
        let variable = "SWIFTDX_TEST_CREDS_TRANSIENT"
        setenv(variable, credsData.base64EncodedString(), 1)
        defer { unsetenv(variable) }
        let resolved = try CredentialsLoader.resolve(.base64Environment(variable: variable))
        switch resolved {
        case .authenticated(let jwt, _): #expect(jwt == "env.jwt")
        case .anonymous: Issue.record("expected authenticated credentials from base64Environment input")
        }
    }

    @Test
    func resolve_base64Environment_throwsWhenVariableNotSet() {
        let variable = "SWIFTDX_TEST_CREDS_ABSENT_\(UUID().uuidString)"
        unsetenv(variable)
        #expect(throws: JetStreamError.self) {
            _ = try CredentialsLoader.resolve(.base64Environment(variable: variable))
        }
    }
}
