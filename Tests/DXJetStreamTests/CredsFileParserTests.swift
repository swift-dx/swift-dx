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

import Testing
@testable import DXJetStream

@Suite
struct CredsFileParserTests {

    @Test
    func credsFileParser_extractsJwtAndSeed() throws {
        let seed = try TestFixtures.encodedSeed()
        let raw = TestFixtures.credentialsFile(jwt: "test.jwt", encodedSeed: seed)
        let credentials = try CredsFileParser.parse(raw)
        #expect(credentials.jwt == "test.jwt")
        #expect(credentials.seed == seed)
    }

    @Test
    func credsFileParser_throwsWhenJwtBlockMissing() throws {
        let seed = try TestFixtures.encodedSeed()
        let raw = """
        -----BEGIN USER NKEY SEED-----
        \(seed)
        ------END USER NKEY SEED------
        """
        #expect(throws: JetStreamError.credentialsJwtMissing) {
            _ = try CredsFileParser.parse(raw)
        }
    }

    @Test
    func credsFileParser_throwsWhenSeedBlockMissing() {
        let raw = """
        -----BEGIN NATS USER JWT-----
        eyJ0eXAiOiJqd3QiLCJhbGciOiJlZDI1NTE5LW5rZXkifQ
        ------END NATS USER JWT------
        """
        #expect(throws: JetStreamError.credentialsSeedMissing) {
            _ = try CredsFileParser.parse(raw)
        }
    }

    @Test
    func credsFileParser_stripsAllWhitespaceFromBlockBodies() throws {
        let raw = """
        -----BEGIN NATS USER JWT-----
        abc
        def

        ghi
        ------END NATS USER JWT------
        -----BEGIN USER NKEY SEED-----
        SU AG CB HH
        ------END USER NKEY SEED------
        """
        let credentials = try CredsFileParser.parse(raw)
        #expect(credentials.jwt == "abcdefghi")
        #expect(credentials.seed == "SUAGCBHH")
    }
}
