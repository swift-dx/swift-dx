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

// TLS configuration for the native TCP path. Pass a `TLSOptions` to
// `ClickHouseClient.Configuration` to enable TLS on the connection;
// pass `nil` for an unencrypted connection.
//
// Three independent knobs:
//
//   - `serverName`: SNI hostname presented during the TLS handshake.
//     Defaults to the connect host. Omitted automatically when the
//     value is an IP literal (RFC 6066 reserves SNI for hostnames).
//   - `trustRoots`: where to load CA certificates from for verifying
//     the server's cert. `.system` uses the OS trust store; `.file`
//     points at a CA bundle on disk for sandboxed deployments.
//   - `clientCertificate` + `clientPrivateKey`: optional mTLS
//     credentials. Both PEM-file paths and in-memory PEM bytes are
//     supported, mapping naturally to disk-mounted certs vs secrets-
//     manager-fetched bytes.
extension ClickHouseClient {

    public struct TLSOptions: Sendable {

        public enum TrustRoots: Sendable {

            case system
            case file(path: String)

        }

        // SNI hostname presented during the TLS handshake.
        // `.derivedFromConnectHost` uses the same hostname the
        // connection dials (the typical setting). `.explicit` overrides
        // that with a separate hostname, useful for connecting via an
        // IP address while still asking the server to use the
        // certificate matching a specific name.
        public enum ServerNameSelection: Sendable, Equatable {

            case derivedFromConnectHost
            case explicit(String)

        }

        // Whether to present a client certificate during the TLS
        // handshake for mutual auth (mTLS). `.none` skips the client-
        // auth half of the handshake; `.provided` carries the
        // certificate + private key to present.
        public enum MutualTLS: Sendable {

            case none
            case provided(certificate: ClientCertificateSource, privateKey: ClientPrivateKeySource)

        }

        // Source for the client's own certificate (presented during the
        // TLS handshake for mutual auth — mTLS). Both file paths and
        // in-memory PEM data are supported; file paths suit deployments
        // that mount certs from disk, in-memory data suits cases where
        // certs come from a secret manager.
        public enum ClientCertificateSource: Sendable {

            case pemFile(path: String)
            case pemBytes([UInt8])

        }

        public enum ClientPrivateKeySource: Sendable {

            case pemFile(path: String)
            case pemBytes([UInt8])

        }

        public let serverName: ServerNameSelection
        public let trustRoots: TrustRoots
        public let mutualTLS: MutualTLS

        public init(
            serverName: ServerNameSelection = .derivedFromConnectHost,
            trustRoots: TrustRoots = .system,
            mutualTLS: MutualTLS = .none
        ) {
            self.serverName = serverName
            self.trustRoots = trustRoots
            self.mutualTLS = mutualTLS
        }

        func makeNIOSSLContext() throws -> NIOSSLContext {
            var configuration = TLSConfiguration.makeClientConfiguration()
            switch trustRoots {
            case .system:
                configuration.trustRoots = .default
            case .file(let path):
                configuration.trustRoots = .file(path)
            }
            switch mutualTLS {
            case .none:
                break
            case .provided(let certificate, let privateKey):
                configuration.certificateChain = try Self.makeCertificateSources(from: certificate)
                configuration.privateKey = try Self.makePrivateKeySource(from: privateKey)
            }
            return try NIOSSLContext(configuration: configuration)
        }

        private static func makeCertificateSources(
            from source: ClientCertificateSource
        ) throws -> [NIOSSLCertificateSource] {
            switch source {
            case .pemFile(let path):
                let certs = try NIOSSLCertificate.fromPEMFile(path)
                return certs.map { .certificate($0) }
            case .pemBytes(let bytes):
                let certs = try NIOSSLCertificate.fromPEMBytes(bytes)
                return certs.map { .certificate($0) }
            }
        }

        private static func makePrivateKeySource(
            from source: ClientPrivateKeySource
        ) throws -> NIOSSLPrivateKeySource {
            switch source {
            case .pemFile(let path):
                let key = try NIOSSLPrivateKey(file: path, format: .pem)
                return .privateKey(key)
            case .pemBytes(let bytes):
                let key = try NIOSSLPrivateKey(bytes: bytes, format: .pem)
                return .privateKey(key)
            }
        }

    }

}
