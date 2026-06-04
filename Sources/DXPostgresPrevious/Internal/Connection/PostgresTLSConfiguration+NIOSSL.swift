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

import NIOSSL

extension PostgresTLSConfiguration {

    enum ResolvedServerName {

        case omitted
        case present(String)
    }

    func resolvedServerName(connectHost: String) -> ResolvedServerName {
        switch serverName {
        case .omitted: .omitted
        case .explicit(let value): .present(value)
        case .derivedFromConnectHost: .present(connectHost)
        }
    }

    func makeContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = try resolveTrustRoots()
        try applyClientIdentity(to: &configuration)
        return try NIOSSLContext(configuration: configuration)
    }

    private func resolveTrustRoots() throws -> NIOSSLTrustRoots {
        switch trustRoots {
        case .system: .default
        case .certificateFile(let path): .file(path)
        }
    }

    private func applyClientIdentity(to configuration: inout TLSConfiguration) throws {
        guard case .pemFiles(let certificatePath, let privateKeyPath) = clientIdentity else { return }
        configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(certificatePath).map { .certificate($0) }
        configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: privateKeyPath, format: .pem))
    }
}
