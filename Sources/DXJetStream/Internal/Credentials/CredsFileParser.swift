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

enum CredsFileParser {

    private static let jwtBegin = "-----BEGIN NATS USER JWT-----"
    private static let jwtEnd = "------END NATS USER JWT------"
    private static let seedBegin = "-----BEGIN USER NKEY SEED-----"
    private static let seedEnd = "------END USER NKEY SEED------"

    static func parse(_ raw: String) throws(JetStreamError) -> NatsCredentials {
        let jwt = try extractBlock(raw, begin: jwtBegin, end: jwtEnd, missingError: .credentialsJwtMissing)
        let seed = try extractBlock(raw, begin: seedBegin, end: seedEnd, missingError: .credentialsSeedMissing)
        return NatsCredentials(jwt: jwt, seed: seed)
    }

    private static func extractBlock(_ raw: String, begin: String, end: String, missingError: JetStreamError) throws(JetStreamError) -> String {
        guard let beginRange = raw.range(of: begin) else {
            throw missingError
        }
        guard let endRange = raw.range(of: end, range: beginRange.upperBound..<raw.endIndex) else {
            throw missingError
        }
        let body = raw[beginRange.upperBound..<endRange.lowerBound]
        let trimmed = body.unicodeScalars
            .filter { !$0.properties.isWhitespace }
            .map(Character.init)
        return String(trimmed)
    }
}
