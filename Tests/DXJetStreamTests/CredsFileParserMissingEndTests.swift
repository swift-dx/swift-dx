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
struct CredsFileParserMissingEndTests {

    @Test
    func parse_throwsJwtMissingWhenJwtBeginPresentButNoEndToken() {
        let raw = """
        -----BEGIN NATS USER JWT-----
        abc.def.ghi
        """
        #expect(throws: JetStreamError.credentialsJwtMissing) {
            _ = try CredsFileParser.parse(raw)
        }
    }

    @Test
    func parse_throwsSeedMissingWhenSeedBeginPresentButNoEndToken() throws {
        let raw = """
        -----BEGIN NATS USER JWT-----
        abc.def.ghi
        ------END NATS USER JWT------
        -----BEGIN USER NKEY SEED-----
        SUAGCBHH
        """
        #expect(throws: JetStreamError.credentialsSeedMissing) {
            _ = try CredsFileParser.parse(raw)
        }
    }
}
