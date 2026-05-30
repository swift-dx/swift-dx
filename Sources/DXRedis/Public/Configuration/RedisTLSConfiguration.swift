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

public struct RedisTLSConfiguration: Sendable {

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
