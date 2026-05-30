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

extension RedisConnection {

    static func connect(endpoint: RedisEndpoint, credentials: RedisCredentials, database: RedisDatabaseIndex, transportSecurity: RedisTransportSecurity, eventLoopGroup: EventLoopGroup, connectTimeout: TimeAmount, requestTimeout: TimeAmount, responseDepthLimit: Int, maxBulkBytes: Int) async throws -> RedisConnection {
        let pending = RedisPendingQueue()
        let channel = try await openChannel(
            endpoint: endpoint,
            transportSecurity: transportSecurity,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout,
            pending: pending,
            responseDepthLimit: responseDepthLimit,
            maxBulkBytes: maxBulkBytes
        )
        let connection = RedisConnection(channel: channel, pending: pending, selectedDatabase: database.value, requestTimeout: requestTimeout)
        try await connection.performHandshake(credentials: credentials, database: database)
        return connection
    }

    private static func openChannel(endpoint: RedisEndpoint, transportSecurity: RedisTransportSecurity, eventLoopGroup: EventLoopGroup, connectTimeout: TimeAmount, pending: RedisPendingQueue, responseDepthLimit: Int, maxBulkBytes: Int) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 256 * 1024, high: 4 * 1024 * 1024))
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 256 * 1024))
            .channelInitializer { channel in
                configurePipeline(
                    channel: channel,
                    endpoint: endpoint,
                    transportSecurity: transportSecurity,
                    pending: pending,
                    responseDepthLimit: responseDepthLimit,
                    maxBulkBytes: maxBulkBytes
                )
            }
        return try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
    }

    private static func configurePipeline(channel: Channel, endpoint: RedisEndpoint, transportSecurity: RedisTransportSecurity, pending: RedisPendingQueue, responseDepthLimit: Int, maxBulkBytes: Int) -> EventLoopFuture<Void> {
        do {
            try addTLSHandlerIfNeeded(channel: channel, endpoint: endpoint, transportSecurity: transportSecurity)
            try channel.pipeline.syncOperations.addHandler(
                RedisInboundHandler(pending: pending, depthLimit: responseDepthLimit, maxBulkBytes: maxBulkBytes, allocator: channel.allocator)
            )
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private static func addTLSHandlerIfNeeded(channel: Channel, endpoint: RedisEndpoint, transportSecurity: RedisTransportSecurity) throws {
        switch transportSecurity {
        case .plaintext: return
        case .tls(let configuration): try addTLSHandler(channel: channel, endpoint: endpoint, configuration: configuration)
        }
    }

    private static func addTLSHandler(channel: Channel, endpoint: RedisEndpoint, configuration: RedisTLSConfiguration) throws {
        let context = try configuration.makeContext()
        let handler = try makeSSLHandler(context: context, serverName: configuration.resolvedServerName(connectHost: endpoint.host))
        try channel.pipeline.syncOperations.addHandler(handler)
    }

    private static func makeSSLHandler(context: NIOSSLContext, serverName: RedisTLSConfiguration.ResolvedServerName) throws -> NIOSSLClientHandler {
        switch serverName {
        case .omitted: try NIOSSLClientHandler(context: context, serverHostname: nil)
        case .present(let value): try NIOSSLClientHandler(context: context, serverHostname: value)
        }
    }

    private func performHandshake(credentials: RedisCredentials, database: RedisDatabaseIndex) async throws {
        try await authenticate(credentials)
        try await selectInitialDatabase(database)
    }

    private func authenticate(_ credentials: RedisCredentials) async throws {
        switch credentials {
        case .none: return
        case .password(let password): try await runAuth(.authenticate(password: password))
        case .usernamePassword(let username, let password): try await runAuth(.authenticate(username: username, password: password))
        }
    }

    private func runAuth(_ command: RedisCommand) async throws {
        let reply = try await send(command)
        try Self.expectOK(reply) { RedisError.authenticationFailed(reason: $0) }
    }

    private func selectInitialDatabase(_ database: RedisDatabaseIndex) async throws {
        guard database.value != 0 else { return }
        let reply = try await send(.selectDatabase(database.value))
        try Self.expectOK(reply) { RedisError.handshakeFailed(reason: $0) }
    }

    static func expectOK(_ reply: RESPValue, mapError: (String) -> RedisError) throws {
        switch reply {
        case .simpleString: return
        case .error(let prefix, let message): throw mapError("\(prefix) \(message)")
        case .bulkString, .integer, .array, .arrayReply, .null: throw RedisError.handshakeFailed(reason: "expected +OK, received \(reply.kindName)")
        }
    }
}
