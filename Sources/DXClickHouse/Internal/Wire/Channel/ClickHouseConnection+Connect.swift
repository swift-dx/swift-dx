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

import NIOCore
import NIOPosix
import NIOSSL

// Factory that opens a TCP socket to a ClickHouse server, drives the
// handshake to negotiate revision, then reconfigures the channel
// pipeline with the typed encoder/decoder + inbound stream handler.
//
// The handshake exchange runs over a temporary `HandshakeReceiver`
// inbound handler that buffers raw bytes into an AsyncThrowingStream.
// Once the handshake completes, that handler is removed and the typed
// pipeline takes over — by the time this factory returns, the
// connection is ready for normal packet exchange.
//
// On any error during connect or handshake, the underlying channel
// is closed before the error propagates. Callers receive either a
// fully-ready connection or an error; never a half-open channel.
extension ClickHouseConnection {

    // `connectTimeout` bounds two phases independently: NIO's TCP
    // connect, then the post-connect handshake (Hello + Addendum +
    // pipeline swap). Worst case the call takes up to ~2x
    // `connectTimeout` if the TCP connect succeeds at the deadline
    // and the server then stalls during the handshake. In practice
    // TCP connect is sub-second on a healthy network, so the
    // post-connect deadline dominates and the effective wait is
    // close to `connectTimeout`.
    static func connect(
        host: String,
        port: Int,
        clientHello: ClickHouseClientHelloPacket,
        eventLoopGroup: EventLoopGroup,
        connectTimeout: TimeAmount = .seconds(10),
        transportSecurity: ClickHouseClient.TransportSecurity = .plaintext,
        compression: ClickHouseCompressionMethod = .uncompressed
    ) async throws -> ClickHouseConnection {
        let receiver = ClickHouseHandshakeReceiver()
        let tlsHandshake: TLSHandshakePreparation
        switch transportSecurity {
        case .plaintext:
            tlsHandshake = .plaintext
        case .tls(let options):
            // SNI carries a hostname per RFC 6066 — passing an IP
            // address here makes NIOSSL throw
            // `cannotUseIPAddressInSNI`. When the resolved name is
            // itself an IP literal (no DNS for the host, or user
            // passed an IP intentionally), omit SNI entirely so the
            // TLS handshake succeeds and certificate verification
            // continues against the cert's SAN/CN per the trust roots.
            let candidateHostname: String
            switch options.serverName {
            case .derivedFromConnectHost: candidateHostname = host
            case .explicit(let explicit): candidateHostname = explicit
            }
            tlsHandshake = .tls(
                context: try options.makeNIOSSLContext(),
                hostname: Self.sniHostname(from: candidateHostname)
            )
        }
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                do {
                    switch tlsHandshake {
                    case .plaintext:
                        break
                    case .tls(let context, let hostname):
                        let sslHandler: NIOSSLClientHandler
                        switch hostname {
                        case .omitted:
                            sslHandler = try NIOSSLClientHandler(context: context, serverHostname: nil)
                        case .present(let value):
                            sslHandler = try NIOSSLClientHandler(context: context, serverHostname: value)
                        }
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }
                    try channel.pipeline.syncOperations.addHandler(receiver)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port)
            .get()

        do {
            // ClientBootstrap.connectTimeout only covers the TCP
            // connect. After that the server can accept TCP and then
            // go quiet (slow-loris, half-open NAT, hung server) on
            // any subsequent write or read. Wrap the entire post-
            // connect phase — opening write, handshake, addendum
            // write, pipeline swap — in a single deadline so the
            // caller never hangs and the doomed channel is torn down.
            return try await Self.runPostConnectWithDeadline(
                channel: channel,
                receiver: receiver,
                clientHello: clientHello,
                compression: compression,
                deadline: connectTimeout
            )
        } catch {
            try? await channel.close()
            throw error
        }
    }

    private static func runHandshake(
        clientHello: ClickHouseClientHelloPacket,
        receiver: ClickHouseHandshakeReceiver
    ) async throws -> ClickHouseConnectionMetadata {
        let handshake = ClickHouseHandshake(clientRevision: clientHello.protocolRevision)
        var accumulator = ByteBuffer()

        for try await chunk in receiver.chunks {
            var incoming = chunk
            accumulator.writeBuffer(&incoming)

            let outcome = try handshake.process(incoming: &accumulator)
            switch outcome {
            case .complete(let revision, let serverHello):
                return ClickHouseConnectionMetadata(
                    negotiatedRevision: revision,
                    clientHello: clientHello,
                    serverHello: serverHello
                )
            case .rejected(let exception):
                throw ClickHouseError.handshakeRejected(serverException: exception.toPublic())
            case .awaitMore:
                continue
            }
        }

        throw ClickHouseError.unexpectedConnectionClose
    }

    // Drives the full post-connect phase (opening write, handshake,
    // addendum write, pipeline swap) and races it against a deadline
    // so a server that goes silent on any subsequent write or read
    // can't hang the caller. The losing branch is cancelled so
    // neither task lingers.
    private static func runPostConnectWithDeadline(
        channel: Channel,
        receiver: ClickHouseHandshakeReceiver,
        clientHello: ClickHouseClientHelloPacket,
        compression: ClickHouseCompressionMethod,
        deadline: TimeAmount
    ) async throws -> ClickHouseConnection {
        try await withThrowingTaskGroup(of: ClickHouseConnection?.self) { group in
            group.addTask {
                try await Self.runPostConnect(
                    channel: channel,
                    receiver: receiver,
                    clientHello: clientHello,
                    compression: compression
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline.nanoseconds)))
                throw ClickHouseError.handshakeTimedOut(timeoutNanoseconds: deadline.nanoseconds)
            }
            defer { group.cancelAll() }
            for try await result in group {
                if let connection = result { return connection }
            }
            throw ClickHouseError.unexpectedConnectionClose
        }
    }

    private static func runPostConnect(
        channel: Channel,
        receiver: ClickHouseHandshakeReceiver,
        clientHello: ClickHouseClientHelloPacket,
        compression: ClickHouseCompressionMethod
    ) async throws -> ClickHouseConnection {
        let openingBytes = try ClickHouseHandshake.openingBytes(clientHello: clientHello)
        try await channel.writeAndFlush(openingBytes).get()

        let metadata = try await Self.runHandshake(
            clientHello: clientHello,
            receiver: receiver
        )

        // Modern CH (>= 54_458) requires an Addendum packet after the
        // server hello and before any Query packet. Send it raw (no
        // encoder, no packet-type marker) per the protocol.
        let revision = metadata.negotiatedRevision
        if revision >= ClickHouseClientAddendumPacket.revisionWithAddendum {
            var addendumBytes = ByteBuffer()
            ClickHouseClientAddendumPacket().encode(into: &addendumBytes, revision: revision)
            try await channel.writeAndFlush(addendumBytes).get()
        }

        let inboundHandler = ClickHouseInboundStreamHandler()
        // ByteToMessageHandler / MessageToByteHandler are explicitly
        // non-Sendable in NIO, so the async pipeline.addHandler refuses
        // them. Hop to the event loop and install via syncOperations.
        try await channel.eventLoop.submit {
            let sync = channel.pipeline.syncOperations
            sync.removeHandler(receiver, promise: nil)
            try sync.addHandler(MessageToByteHandler(ClickHouseOutboundEncoder(revision: revision, compression: compression)))
            try sync.addHandler(ByteToMessageHandler(ClickHouseInboundDecoder(revision: revision, compression: compression)))
            try sync.addHandler(inboundHandler)
        }.get()

        return ClickHouseConnection(
            channel: channel,
            inboundHandler: inboundHandler,
            metadata: metadata,
            compression: compression
        )
    }

    // Runs `runHandshake` against a wall-clock deadline. Kept separate
    // from `runPostConnectWithDeadline` so the test that proves the
    // deadline mechanism doesn't need a live TCP socket.
    static func runHandshakeWithDeadline(
        clientHello: ClickHouseClientHelloPacket,
        receiver: ClickHouseHandshakeReceiver,
        deadline: TimeAmount
    ) async throws -> ClickHouseConnectionMetadata {
        try await withThrowingTaskGroup(of: ClickHouseConnectionMetadata?.self) { group in
            group.addTask {
                try await Self.runHandshake(clientHello: clientHello, receiver: receiver)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, deadline.nanoseconds)))
                throw ClickHouseError.handshakeTimedOut(timeoutNanoseconds: deadline.nanoseconds)
            }
            defer { group.cancelAll() }
            for try await result in group {
                if let metadata = result { return metadata }
            }
            throw ClickHouseError.unexpectedConnectionClose
        }
    }

    // Returns `.omitted` when `value` parses as an IPv4 or IPv6 literal
    // so the SNI extension is omitted (RFC 6066 reserves SNI for
    // hostnames). Returns the original string otherwise. Reuses NIO's
    // own IP-format validation via `SocketAddress(ipAddress:port:)`
    // rather than a hand-rolled regex — same parser the bootstrap uses
    // to resolve the eventual connect target.
    static func sniHostname(from value: String) -> SNIHostnameSelection {
        if (try? SocketAddress(ipAddress: value, port: 0)) != nil {
            return .omitted
        }
        return .present(value)
    }

}

// Whether SNI is present on the TLS ClientHello. `omitted` means no
// SNI extension is sent (IP-literal target).
enum SNIHostnameSelection: Sendable, Equatable {

    case omitted
    case present(String)

}

private enum TLSHandshakePreparation {

    case plaintext
    case tls(context: NIOSSLContext, hostname: SNIHostnameSelection)

}
