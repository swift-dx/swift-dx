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
import Foundation

enum CredentialsLoader {

    static func resolve(_ source: NatsCredentialsSource) throws(JetStreamError) -> ResolvedCredentials {
        switch source {
        case .anonymous:
            return .anonymous
        case .literal(let credentials):
            return try authenticated(from: credentials)
        case .base64String(let encoded):
            return try authenticated(fromBase64: encoded)
        case .base64Environment(let variable):
            guard let raw = ProcessInfo.processInfo.environment[variable], !raw.isEmpty else {
                throw JetStreamError.credentialsEnvironmentMissing(variable: variable)
            }
            return try authenticated(fromBase64: raw)
        }
    }

    private static func authenticated(from credentials: NatsCredentials) throws(JetStreamError) -> ResolvedCredentials {
        let seed = try NKeySeed.decode(credentials.seed)
        let signer = try Ed25519Signer(seed: seed)
        return .authenticated(jwt: credentials.jwt, signer: signer)
    }

    private static func authenticated(fromBase64 encoded: String) throws(JetStreamError) -> ResolvedCredentials {
        let raw: [UInt8]
        do {
            raw = try Base64.decode(encoded)
        } catch {
            throw JetStreamError.credentialsBase64Invalid(reason: "invalid base64 character")
        }
        let text = String(decoding: raw, as: UTF8.self)
        let credentials = try CredsFileParser.parse(text)
        return try authenticated(from: credentials)
    }
}
