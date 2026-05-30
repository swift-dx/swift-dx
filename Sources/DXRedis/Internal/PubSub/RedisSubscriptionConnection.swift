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

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

// One TCP connection dedicated to subscribe mode. It carries no pending-reply
// queue: once authenticated it only ever sends SUBSCRIBE/UNSUBSCRIBE frames and
// receives push frames, which the inbound handler routes to the manager. The
// channel is event-loop pinned and the closing flag is lock-guarded, so sharing
// it across threads is safe (`@unchecked Sendable`).
final class RedisSubscriptionConnection: @unchecked Sendable {

    let channel: Channel
    private let closing = NIOLockedValueBox(false)

    init(channel: Channel) {
        self.channel = channel
    }

    static func connect(
        endpoint: RedisEndpoint,
        credentials: RedisCredentials,
        transportSecurity: RedisTransportSecurity,
        eventLoopGroup: EventLoopGroup,
        connectTimeout: TimeAmount,
        depthLimit: Int,
        maxBulkBytes: Int,
        onFrame: @escaping @Sendable (RESPValue) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> RedisSubscriptionConnection {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4 * 1024 * 1024)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 256 * 1024))
            .channelInitializer { channel in
                Self.configurePipeline(channel: channel, endpoint: endpoint, transportSecurity: transportSecurity, depthLimit: depthLimit, maxBulkBytes: maxBulkBytes, onFrame: onFrame, onClose: onClose)
            }
        let channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        let connection = RedisSubscriptionConnection(channel: channel)
        try connection.authenticate(credentials)
        return connection
    }

    private static func configurePipeline(channel: Channel, endpoint: RedisEndpoint, transportSecurity: RedisTransportSecurity, depthLimit: Int, maxBulkBytes: Int, onFrame: @escaping @Sendable (RESPValue) -> Void, onClose: @escaping @Sendable () -> Void) -> EventLoopFuture<Void> {
        do {
            try addTLSHandlerIfNeeded(channel: channel, endpoint: endpoint, transportSecurity: transportSecurity)
            try channel.pipeline.syncOperations.addHandler(
                RedisSubscriptionInboundHandler(depthLimit: depthLimit, maxBulkBytes: maxBulkBytes, allocator: channel.allocator, onFrame: onFrame, onClose: onClose)
            )
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private static func addTLSHandlerIfNeeded(channel: Channel, endpoint: RedisEndpoint, transportSecurity: RedisTransportSecurity) throws {
        switch transportSecurity {
        case .plaintext: return
        case .tls(let configuration):
            let context = try configuration.makeContext()
            let handler = try makeSSLHandler(context: context, serverName: configuration.resolvedServerName(connectHost: endpoint.host))
            try channel.pipeline.syncOperations.addHandler(handler)
        }
    }

    private static func makeSSLHandler(context: NIOSSLContext, serverName: RedisTLSConfiguration.ResolvedServerName) throws -> NIOSSLClientHandler {
        switch serverName {
        case .omitted: try NIOSSLClientHandler(context: context, serverHostname: nil)
        case .present(let value): try NIOSSLClientHandler(context: context, serverHostname: value)
        }
    }

    private func authenticate(_ credentials: RedisCredentials) throws {
        switch credentials {
        case .none: return
        case .password(let password): send(.authenticate(password: password))
        case .usernamePassword(let username, let password): send(.authenticate(username: username, password: password))
        }
    }

    var isActive: Bool {
        guard !closing.withLockedValue({ $0 }) else { return false }
        return channel.isActive
    }

    func send(_ command: RedisCommand) {
        let buffer = RESPBatchWriter.encodeCommands([command], allocator: channel.allocator)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func close() async {
        closing.withLockedValue { $0 = true }
        try? await channel.close().get()
    }
}
