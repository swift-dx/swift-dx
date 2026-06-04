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

/// How the client establishes and verifies a TLS session once the server has
/// agreed to it. `serverName` controls the SNI value and certificate-hostname
/// check, `trustRoots` selects the certificate authorities trusted to sign the
/// server certificate, and `clientIdentity` supplies a client certificate for
/// mutual TLS when the server requires one.
public struct PostgresTLSConfiguration: Sendable {

    public enum ServerName: Sendable, Equatable {

        case derivedFromConnectHost
        case explicit(String)
        case omitted
    }

    public enum TrustRoots: Sendable, Equatable {

        case system
        case certificateFile(path: String)
    }

    public enum ClientIdentity: Sendable, Equatable {

        case none
        case pemFiles(certificatePath: String, privateKeyPath: String)
    }

    public let serverName: ServerName
    public let trustRoots: TrustRoots
    public let clientIdentity: ClientIdentity

    public init(serverName: ServerName = .derivedFromConnectHost, trustRoots: TrustRoots = .system, clientIdentity: ClientIdentity = .none) {
        self.serverName = serverName
        self.trustRoots = trustRoots
        self.clientIdentity = clientIdentity
    }
}
