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

@testable import DXClickHouse
import NIOPosix
import NIOSSL
import Testing

@Suite("ClickHouse TLSOptions")
struct ClickHouseTLSOptionsTests {

    @Test("default TLSOptions uses system trust roots and derives the SNI name from the connect host")
    func defaultTLSOptions() {
        let options = ClickHouseClient.TLSOptions()
        #expect(options.serverName == .derivedFromConnectHost)
        switch options.trustRoots {
        case .system:
            break
        case .file:
            Issue.record("expected .system, got .file")
        }
    }

    @Test("TLSOptions with explicit server name preserves it for SNI / hostname verification")
    func tlsOptionsWithServerName() {
        let options = ClickHouseClient.TLSOptions(serverName: .explicit("ch.example.com"))
        #expect(options.serverName == .explicit("ch.example.com"))
    }

    @Test("TLSOptions with file-based trust roots preserves the path")
    func tlsOptionsWithFileTrustRoots() {
        let options = ClickHouseClient.TLSOptions(
            serverName: .explicit("ch.example.com"),
            trustRoots: .file(path: "/path/to/ca.pem")
        )
        switch options.trustRoots {
        case .system:
            Issue.record("expected .file, got .system")
        case .file(let path):
            #expect(path == "/path/to/ca.pem")
        }
    }

    @Test("makeNIOSSLContext succeeds with system trust roots")
    func makeNIOSSLContextWithSystemTrust() throws {
        let options = ClickHouseClient.TLSOptions()
        _ = try options.makeNIOSSLContext()
    }

    @Test("default TLSOptions has .none for mutualTLS (server-only TLS, not mTLS)")
    func defaultTLSOptionsHasNoClientCert() {
        let options = ClickHouseClient.TLSOptions()
        guard case .none = options.mutualTLS else {
            Issue.record("expected .none")
            return
        }
    }

    @Test("TLSOptions preserves the client certificate file path")
    func clientCertFilePathPreserved() {
        let options = ClickHouseClient.TLSOptions(
            serverName: .explicit("ch.example.com"),
            mutualTLS: .provided(
                certificate: .pemFile(path: "/etc/ssl/client.crt"),
                privateKey: .pemFile(path: "/etc/ssl/client.key")
            )
        )
        guard case .provided(let certificate, _) = options.mutualTLS else {
            Issue.record("expected .provided")
            return
        }
        switch certificate {
        case .pemFile(let path):
            #expect(path == "/etc/ssl/client.crt")
        case .pemBytes:
            Issue.record("expected .pemFile, got .pemBytes")
        }
    }

    @Test("TLSOptions preserves the client private key bytes")
    func clientKeyBytesPreserved() {
        let bytes: [UInt8] = [0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x42, 0x45, 0x47, 0x49, 0x4E] // "-----BEGIN"
        let options = ClickHouseClient.TLSOptions(
            mutualTLS: .provided(
                certificate: .pemFile(path: "/etc/ssl/client.crt"),
                privateKey: .pemBytes(bytes)
            )
        )
        guard case .provided(_, let key) = options.mutualTLS else {
            Issue.record("expected .provided")
            return
        }
        switch key {
        case .pemBytes(let actual):
            #expect(actual == bytes)
        default:
            Issue.record("expected .pemBytes")
        }
    }

    @Test("TLSOptions can carry both clientCertificate and clientPrivateKey for mTLS")
    func bothClientCertAndKeyForMTLS() {
        let options = ClickHouseClient.TLSOptions(
            serverName: .explicit("ch.example.com"),
            mutualTLS: .provided(
                certificate: .pemFile(path: "/etc/ssl/client.crt"),
                privateKey: .pemFile(path: "/etc/ssl/client.key")
            )
        )
        guard case .provided = options.mutualTLS else {
            Issue.record("expected .provided")
            return
        }
    }

    @Test("makeNIOSSLContext throws when the client cert file path doesn't exist")
    func clientCertMissingFileThrows() {
        let options = ClickHouseClient.TLSOptions(
            mutualTLS: .provided(
                certificate: .pemFile(path: "/nonexistent/client.crt"),
                privateKey: .pemFile(path: "/nonexistent/client.key")
            )
        )
        #expect(throws: (any Error).self) {
            _ = try options.makeNIOSSLContext()
        }
    }

    @Test("makeNIOSSLContext throws when client cert PEM bytes are malformed")
    func clientCertMalformedBytesThrows() {
        let options = ClickHouseClient.TLSOptions(
            mutualTLS: .provided(
                certificate: .pemBytes([0x00, 0x01, 0x02, 0x03]),  // not PEM
                privateKey: .pemBytes([0x00, 0x01, 0x02, 0x03])
            )
        )
        #expect(throws: (any Error).self) {
            _ = try options.makeNIOSSLContext()
        }
    }

    @Test("makeNIOSSLContext succeeds with no client cert (server-only TLS, baseline)")
    func makeContextWithoutClientCertSucceeds() throws {
        let options = ClickHouseClient.TLSOptions()
        _ = try options.makeNIOSSLContext()
    }

    @Test("Configuration accepts a TransportSecurity and threads it through poolConfiguration")
    func configurationCarriesTLSOptions() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let configWithTLS = ClickHouseClient.Configuration(
            endpoints: [.init(host: "ch.example.com", port: 9440)],
            eventLoopGroup: group,
            transportSecurity: .tls(.init(serverName: .explicit("ch.example.com")))
        )
        guard case .tls(let options) = configWithTLS.transportSecurity else {
            Issue.record("expected .tls")
            return
        }
        #expect(options.serverName == .explicit("ch.example.com"))

        let configWithoutTLS = ClickHouseClient.Configuration(
            endpoints: [.init(host: "ch.internal", port: 9000)],
            eventLoopGroup: group
        )
        guard case .plaintext = configWithoutTLS.transportSecurity else {
            Issue.record("expected .plaintext")
            return
        }
    }

}
