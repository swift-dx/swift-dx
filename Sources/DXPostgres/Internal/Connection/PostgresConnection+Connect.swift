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

extension PostgresConnection {

    static func connect(endpoint: PostgresEndpoint, credentials: PostgresCredentials, database: PostgresDatabaseName, applicationName: String, transportSecurity: PostgresTransportSecurity, eventLoopGroup: EventLoopGroup, connectTimeout: TimeAmount, requestTimeout: TimeAmount) async throws(PostgresError) -> PostgresConnection {
        try await PostgresError.bridge {
            let stream = PostgresMessageStream()
            let channel = try await openChannel(endpoint: endpoint, group: eventLoopGroup, connectTimeout: connectTimeout)
            try await negotiateTLS(channel: channel, transportSecurity: transportSecurity, endpoint: endpoint)
            try await channel.pipeline.addHandler(PostgresInboundHandler(stream: stream, allocator: channel.allocator)).get()
            let connection = PostgresConnection(channel: channel, stream: stream, requestTimeout: requestTimeout, connectTimeout: connectTimeout)
            try await connection.performStartup(credentials: credentials, database: database, applicationName: applicationName)
            return connection
        }
    }

    private static func openChannel(endpoint: PostgresEndpoint, group: EventLoopGroup, connectTimeout: TimeAmount) async throws -> Channel {
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
        return try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
    }

    private static func negotiateTLS(channel: Channel, transportSecurity: PostgresTransportSecurity, endpoint: PostgresEndpoint) async throws {
        guard case .tls(let configuration) = transportSecurity else { return }
        let accepted = try await requestTLS(on: channel)
        guard accepted else { throw PostgresError.tlsNotSupportedByServer }
        try await addTLSHandler(channel: channel, configuration: configuration, endpoint: endpoint)
    }

    private static func requestTLS(on channel: Channel) async throws -> Bool {
        let responseByte = channel.eventLoop.makePromise(of: UInt8.self)
        try await channel.pipeline.addHandler(SSLNegotiationResponseHandler(responseByte: responseByte)).get()
        try await channel.writeAndFlush(FrontendMessage.sslRequest(allocator: channel.allocator)).get()
        return try interpretTLSResponse(try await responseByte.futureResult.get())
    }

    private static func interpretTLSResponse(_ byte: UInt8) throws -> Bool {
        switch byte {
        case 0x53: return true
        case 0x4e: return false
        default: throw PostgresError.protocolError(reason: "unexpected SSLRequest response byte \(byte)")
        }
    }

    private static func addTLSHandler(channel: Channel, configuration: PostgresTLSConfiguration, endpoint: PostgresEndpoint) async throws {
        let context = try configuration.makeContext()
        let serverName = configuration.resolvedServerName(connectHost: endpoint.host)
        // NIOSSLHandler is not Sendable, so build and install it on the channel's
        // event loop rather than handing it to the cross-thread addHandler.
        try await channel.eventLoop.submit {
            let handler = try makeSSLHandler(context: context, serverName: serverName)
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }.get()
    }

    private static func makeSSLHandler(context: NIOSSLContext, serverName: PostgresTLSConfiguration.ResolvedServerName) throws -> NIOSSLClientHandler {
        switch serverName {
        case .omitted: try NIOSSLClientHandler(context: context, serverHostname: nil)
        case .present(let value): try NIOSSLClientHandler(context: context, serverHostname: value)
        }
    }

    func performStartup(credentials: PostgresCredentials, database: PostgresDatabaseName, applicationName: String) async throws(PostgresError) {
        try await runBounded(timeout: connectTimeout) {
            self.write(FrontendMessage.startup(user: credentials.username, database: database.value, applicationName: applicationName, allocator: self.channel.allocator))
            try await self.runAuthentication(credentials)
            try await self.awaitReadyForQuery()
        }
    }

    private func runAuthentication(_ credentials: PostgresCredentials) async throws(PostgresError) {
        var done = false
        while !done {
            done = try await stepAuthentication(credentials)
        }
    }

    private func stepAuthentication(_ credentials: PostgresCredentials) async throws(PostgresError) -> Bool {
        let message = try await nextBackendMessage()
        guard case .authentication(let request) = message else {
            throw authenticationFailure(for: message)
        }
        return try await respondToAuthentication(request, credentials: credentials)
    }

    private func respondToAuthentication(_ request: AuthenticationRequest, credentials: PostgresCredentials) async throws(PostgresError) -> Bool {
        switch request {
        case .ok: return true
        case .cleartextPassword: try await sendCleartextPassword(credentials); return false
        case .md5Password(let salt): try await sendMd5Password(credentials, salt: salt); return false
        case .saslMechanisms(let mechanisms): try await runScram(credentials, mechanisms: mechanisms); return false
        case .saslContinue, .saslFinal: throw PostgresError.protocolError(reason: "received a SASL continuation outside an in-progress SCRAM exchange")
        case .unsupported(let code): throw PostgresError.unsupportedAuthentication(method: "authentication code \(code)")
        }
    }

    private func sendCleartextPassword(_ credentials: PostgresCredentials) async throws(PostgresError) {
        let password = try requirePassword(credentials)
        write(FrontendMessage.password(Array(password.utf8), allocator: channel.allocator))
    }

    private func sendMd5Password(_ credentials: PostgresCredentials, salt: [UInt8]) async throws(PostgresError) {
        let password = try requirePassword(credentials)
        let token = Md5Authentication.token(username: credentials.username, password: password, salt: salt)
        write(FrontendMessage.password(token, allocator: channel.allocator))
    }

    private func runScram(_ credentials: PostgresCredentials, mechanisms: [String]) async throws(PostgresError) {
        let password = try requirePassword(credentials)
        try requireScramSupport(mechanisms)
        var client = ScramClient(username: "", password: password, clientNonce: ScramNonce.generate())
        write(FrontendMessage.saslInitialResponse(mechanism: "SCRAM-SHA-256", initialResponse: client.clientFirstMessage(), allocator: channel.allocator))
        let serverFirst = try await expectSASLContinue()
        write(FrontendMessage.saslResponse(try client.clientFinalMessage(serverFirst: serverFirst), allocator: channel.allocator))
        let serverFinal = try await expectSASLFinal()
        try client.verifyServerFinal(serverFinal)
    }

    private func requireScramSupport(_ mechanisms: [String]) throws(PostgresError) {
        guard mechanisms.contains("SCRAM-SHA-256") else {
            throw PostgresError.unsupportedAuthentication(method: "SASL mechanisms \(mechanisms.joined(separator: ", "))")
        }
    }

    private func expectSASLContinue() async throws(PostgresError) -> [UInt8] {
        let message = try await nextBackendMessage()
        guard case .authentication(.saslContinue(let data)) = message else {
            throw authenticationFailure(for: message)
        }
        return data
    }

    private func expectSASLFinal() async throws(PostgresError) -> [UInt8] {
        let message = try await nextBackendMessage()
        guard case .authentication(.saslFinal(let data)) = message else {
            throw authenticationFailure(for: message)
        }
        return data
    }

    private func requirePassword(_ credentials: PostgresCredentials) throws(PostgresError) -> String {
        guard case .password(_, let password) = credentials else {
            throw PostgresError.authenticationFailed(reason: "the server requested a password but trust credentials were supplied")
        }
        return password
    }

    private func authenticationFailure(for message: BackendMessage) -> PostgresError {
        if case .error(let error) = message {
            return .server(error)
        }
        return .protocolError(reason: "expected an authentication message during the startup handshake")
    }

    private func awaitReadyForQuery() async throws(PostgresError) {
        var ready = false
        while !ready {
            ready = try await consumeStartupMessage()
        }
    }

    private func consumeStartupMessage() async throws(PostgresError) -> Bool {
        let message = try await nextBackendMessage()
        switch message {
        case .readyForQuery: return true
        case .error(let error): throw PostgresError.server(error)
        default: return try acceptStartupTransientMessage(message)
        }
    }

    private func acceptStartupTransientMessage(_ message: BackendMessage) throws(PostgresError) -> Bool {
        switch message {
        case .parameterStatus, .backendKeyData, .notice: return false
        default: throw PostgresError.protocolError(reason: "unexpected message during the startup handshake")
        }
    }
}
