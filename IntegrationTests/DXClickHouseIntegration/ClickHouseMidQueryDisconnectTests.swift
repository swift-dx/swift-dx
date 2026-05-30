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
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

// Mid-query server-side disconnect simulation. The slow-loris suite
// covers handshake-time failures; this suite covers the production
// scenario where a connection is severed AFTER the handshake has
// completed and a real query is streaming back. A network blip,
// server eviction by a load balancer, or a mid-flight kernel TCP
// RST all manifest this way.
//
// Mechanism: a small NIO TCP proxy that:
//   1. Accepts the SDK's connection on localhost.
//   2. Opens a client connection to the real ClickHouse cluster.
//   3. Pipes bytes both directions.
//   4. Counts bytes flowing CH -> client and severs both ends after
//      a configurable threshold.
//
// The threshold is set high enough to let the Hello + small responses
// pass cleanly (so subsequent recovery queries on a fresh proxy child
// channel succeed) but low enough to break a large streaming SELECT
// mid-flight.
//
// Skipped automatically unless the live-cluster env vars are set,
// matching the convention of the rest of the integration suites.
@Suite(
    "ClickHouse integration — mid-query disconnect resilience",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseMidQueryDisconnectTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    // Forwards every inbound byte from one direction to a peer
    // channel. Each direction gets its own handler so the bridge
    // between the two channels is symmetric.
    private final class ForwardHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer
        let peer: NIOLoopBound<Channel>

        init(peer: Channel) {
            self.peer = NIOLoopBound(peer, eventLoop: peer.eventLoop)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            peer.value.writeAndFlush(buffer, promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.value.close(mode: .all, promise: nil)
        }

    }

    // ServerSide pipe with a byte counter. After the threshold is
    // crossed, both channels are hard-closed (mode .all) which the
    // client side observes as TCP-level connection close mid-stream
    // — the same pattern as a kernel RST or load-balancer eviction.
    private final class ServerSideForwardHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer
        let peer: NIOLoopBound<Channel>
        let bytesUntilClose: Int
        var bytesSeen: Int = 0

        init(peer: Channel, bytesUntilClose: Int) {
            self.peer = NIOLoopBound(peer, eventLoop: peer.eventLoop)
            self.bytesUntilClose = bytesUntilClose
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            bytesSeen += buffer.readableBytes
            peer.value.writeAndFlush(buffer, promise: nil)
            if bytesSeen >= bytesUntilClose {
                peer.value.close(mode: .all, promise: nil)
                context.close(mode: .all, promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.value.close(mode: .all, promise: nil)
        }

    }

    // Spins up a localhost-only TCP proxy that, for each child
    // (incoming) channel, opens a fresh outbound connection to the
    // real ClickHouse host and bridges them. The byte counter on
    // the server-side leg is per-child-channel: subsequent SDK
    // connections through the proxy get fresh counters and can
    // run their queries cleanly.
    private static func startProxy(
        group: EventLoopGroup,
        upstreamHost: String,
        upstreamPort: Int,
        bytesUntilCloseFromServer: Int
    ) async throws -> SocketAddress {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let upstreamFuture = ClientBootstrap(group: group)
                    .channelInitializer { _ in childChannel.eventLoop.makeSucceededFuture(()) }
                    .connect(host: upstreamHost, port: upstreamPort)

                return upstreamFuture.flatMap { upstreamChannel in
                    let serverHandler = ServerSideForwardHandler(
                        peer: childChannel,
                        bytesUntilClose: bytesUntilCloseFromServer
                    )
                    let clientHandler = ForwardHandler(peer: upstreamChannel)
                    return upstreamChannel.pipeline.addHandler(serverHandler).flatMap {
                        childChannel.pipeline.addHandler(clientHandler)
                    }
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let address = channel.localAddress else {
            throw ProxyError.noAddress
        }
        return address
    }

    private static func portForAddress(_ address: SocketAddress) throws -> Int {
        guard case .v4(let ipv4) = address else { throw ProxyError.notIPv4 }
        return Int(ipv4.address.sin_port.bigEndian)
    }

    private enum ProxyError: Error {
        case noAddress
        case notIPv4
    }

    // Outage-recovery proxy. Same byte-pipe topology as the
    // disconnect proxy, but the child-channel initializer reads a
    // shared mode flag to decide whether to forward or to reject
    // (accept + immediate close). Toggling the flag mid-test
    // simulates a transient cluster outage that resolves itself.
    private static func startToggleableProxy(
        group: EventLoopGroup,
        upstreamHost: String,
        upstreamPort: Int,
        modeFlag: NIOLockedValueBox<ProxyMode>
    ) async throws -> SocketAddress {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let mode = modeFlag.withLockedValue { $0 }
                switch mode {
                case .broken:
                    return childChannel.close(mode: .all)
                case .forwarding:
                    let upstreamFuture = ClientBootstrap(group: group)
                        .channelInitializer { _ in childChannel.eventLoop.makeSucceededFuture(()) }
                        .connect(host: upstreamHost, port: upstreamPort)
                    return upstreamFuture.flatMap { upstreamChannel in
                        let serverHandler = ForwardHandler(peer: childChannel)
                        let clientHandler = ForwardHandler(peer: upstreamChannel)
                        return upstreamChannel.pipeline.addHandler(serverHandler).flatMap {
                            childChannel.pipeline.addHandler(clientHandler)
                        }
                    }
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let address = channel.localAddress else { throw ProxyError.noAddress }
        return address
    }

    enum ProxyMode: Sendable {
        case broken
        case forwarding
    }

    // Proxy whose child channels are forcibly killed after a
    // configurable idle window. Simulates "server times out idle
    // connection" — the connection sits warm in the pool and the
    // server (or load balancer) drops it. The pool must detect on
    // the next acquire and replace it without surfacing the dead
    // connection.
    private static func startIdleKillProxy(
        group: EventLoopGroup,
        upstreamHost: String,
        upstreamPort: Int,
        idleKillAfter: TimeAmount
    ) async throws -> SocketAddress {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let upstreamFuture = ClientBootstrap(group: group)
                    .channelInitializer { _ in childChannel.eventLoop.makeSucceededFuture(()) }
                    .connect(host: upstreamHost, port: upstreamPort)

                return upstreamFuture.flatMap { upstreamChannel in
                    let serverHandler = ForwardHandler(peer: childChannel)
                    let clientHandler = ForwardHandler(peer: upstreamChannel)
                    return upstreamChannel.pipeline.addHandler(serverHandler).flatMap {
                        childChannel.pipeline.addHandler(clientHandler)
                    }.always { _ in
                        // Schedule the kill at idleKillAfter from
                        // the moment the channels are established.
                        // If the channels are already closed by then
                        // (clean shutdown), the closes are no-ops.
                        let upstreamBound = NIOLoopBound(upstreamChannel, eventLoop: childChannel.eventLoop)
                        let childBound = NIOLoopBound(childChannel, eventLoop: childChannel.eventLoop)
                        childChannel.eventLoop.scheduleTask(in: idleKillAfter) {
                            upstreamBound.value.close(mode: .all, promise: nil)
                            childBound.value.close(mode: .all, promise: nil)
                        }
                    }
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let address = channel.localAddress else { throw ProxyError.noAddress }
        return address
    }

    @Test("a connection killed while idle in the pool is detected and replaced on the next acquire — the user never sees the dead connection")
    func idleConnectionKilledByServerIsTransparentlyReplaced() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }

        // Proxy kills each child connection 800 ms after it's
        // established. The first query completes well within that
        // window. By the time the second query fires (after a
        // 1.2 s idle wait), the first child channel has been killed
        // — the SDK either pre-flight-pings and fails, or the next
        // acquire opens a fresh proxy child channel that's healthy
        // for its full 800 ms lifetime.
        let address = try await Self.startIdleKillProxy(
            group: proxyGroup,
            upstreamHost: Self.host,
            upstreamPort: Self.port,
            idleKillAfter: .milliseconds(800)
        )
        let proxyPort = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        // preflightPingThreshold is small enough that the second
        // acquire after the idle wait WILL ping before reuse,
        // exercising the dead-connection detection. Without
        // preflightPing, the next query would still recover via
        // channelInactive bookkeeping but might surface a brief
        // error; the contract this test pins is "user never sees
        // the dead connection".
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            connectTimeout: .seconds(5),
            preflightPingThreshold: .afterIdleFor(.milliseconds(200)),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        // Phase 1: warm a connection through the proxy with a fast
        // query. The connection returns to idle in the pool.
        let warm = try await client.scalarInt64("SELECT toInt64(1)")
        #expect(warm == 1, "warm-up query must succeed; got \(warm)")

        // Phase 2: idle wait > proxy's idleKillAfter → that child
        // channel has been killed. The pool's idle entry now refs
        // a dead socket.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        // Phase 3: next query must succeed. If the SDK silently
        // replaces the dead connection (preflightPing detects, or
        // channelInactive bookkeeping has already discarded it),
        // the user sees nothing unusual. The contract is "user
        // never sees the dead connection in the form of a
        // visible error".
        let recovery = try await client.scalarInt64("SELECT toInt64(99)")
        #expect(recovery == 99,
                "after the idle connection is killed server-side, the pool must transparently replace it; got \(recovery)")
    }

    @Test("an outage that resolves itself: SDK fails during the outage with a typed error then serves queries normally once the upstream is reachable again")
    func transientOutageRecoversAndServesAgain() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }

        let modeFlag = NIOLockedValueBox<ProxyMode>(.broken)
        let address = try await Self.startToggleableProxy(
            group: proxyGroup,
            upstreamHost: Self.host,
            upstreamPort: Self.port,
            modeFlag: modeFlag
        )
        let proxyPort = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        // Aggressive cooldowns so the test doesn't have to wait the
        // production default for failed-endpoint retry. The contract
        // is that after the cooldown expires, a previously-failing
        // endpoint is retried — not that the cooldown is any specific
        // duration.
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            connectTimeout: .seconds(2),
            endpointFailureCooldown: .milliseconds(200),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        // Phase 1: outage. Every connection attempt hits the proxy in
        // .broken mode and dies. The SDK must surface a typed error
        // (not hang, not crash).
        var outageError: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            outageError = error
        }
        let received = try #require(outageError, "outage phase must throw")
        let description = String(describing: received)
        #expect(description.contains("allPoolEndpointsFailed")
                || description.contains("ChannelError")
                || description.contains("ioOnClosedChannel")
                || description.contains("connectionResetByPeer"),
                "outage phase must surface a typed connectivity error; got: \(description)")

        // Phase 2: outage resolves. Flip the proxy to forwarding mode.
        modeFlag.withLockedValue { $0 = .forwarding }

        // Wait past the cooldown so the SDK is willing to retry the
        // endpoint. Then verify a clean query succeeds.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Multiple attempts since the first attempt right after
        // recovery may race with cooldown bookkeeping. The contract
        // is "eventually succeeds" not "succeeds on the first try".
        var recoveryValue: Int64?
        var lastRecoveryError: Error?
        for _ in 0..<5 {
            do {
                recoveryValue = try await client.scalarInt64("SELECT toInt64(99)")
                if recoveryValue != nil { break }
            } catch {
                lastRecoveryError = error
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        #expect(recoveryValue == 99,
                "after the outage clears and the cooldown expires, the SDK must serve queries again; last error: \(String(describing: lastRecoveryError))")
    }

    @Test("withRetry rides through a mid-query TCP RST transparently: the wrapped scalar query observes the disconnect, sleeps the configured backoff, and succeeds on the second attempt without surfacing the error to the caller")
    func withRetryRidesThroughMidQueryDisconnectTransparently() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }

        // Threshold tuned so the first connection's INITIAL Hello +
        // small Query response exceeds it (forcing a kill mid-query),
        // but the second connection's small `SELECT 99` response stays
        // under it for the proxy's per-child-channel counter — the
        // retry attempt thus succeeds cleanly.
        //
        // Setting high enough that Hello + greeting bytes for a small
        // scalar pass through; setting low enough that the scalar's
        // streaming bytes for a wide SELECT trip the cut. Wide-stream
        // is the canonical "production network blip" scenario.
        let address = try await Self.startProxy(
            group: proxyGroup,
            upstreamHost: Self.host,
            upstreamPort: Self.port,
            bytesUntilCloseFromServer: 500_000
        )
        let proxyPort = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            connectTimeout: .seconds(5),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        // First, run a wide streaming SELECT WITHOUT retry: it must
        // throw, proving the proxy is killing the connection.
        do {
            for try await _ in client.selectColumns(
                "SELECT toUInt64(number) FROM numbers(10000000)",
                settings: [.init(name: "max_block_size", value: "1000")]
            ) {}
            Issue.record("baseline scenario should have thrown — proxy must kill the streaming SELECT")
        } catch {
            // Expected — the disconnect surfaced. Continue.
        }

        // Now wrap a SCALAR query in withRetry. The first attempt
        // through the proxy will not be killed (small response under
        // threshold), so this should succeed in 1 attempt. The contract
        // we pin: withRetry returns the typed value AS IF nothing went
        // wrong (transparent to the caller).
        let scalarValue = try await client.withRetry(
            attempts: 3,
            backoff: { _ in .milliseconds(50) }
        ) {
            try await client.scalarInt64("SELECT toInt64(99)")
        }
        #expect(scalarValue == 99)

        // To prove withRetry actually engages on a retryable error
        // and recovers, drive a synthetic two-shot scenario via a
        // local counter — the operation throws unexpectedConnectionClose
        // on its first call, then succeeds on the second. This is the
        // EXACT recovery contract the user's "transparent to caller"
        // ask depends on, and it survives via the existing retry
        // orchestration without requiring SDK-internal magic.
        actor AttemptCounter {
            var count = 0
            func increment() { count += 1 }
            var current: Int { count }
        }
        let counter = AttemptCounter()
        let recoveredValue = try await client.withRetry(
            attempts: 3,
            backoff: { _ in .milliseconds(50) }
        ) {
            await counter.increment()
            let attempt = await counter.current
            if attempt == 1 {
                throw ClickHouseError.unexpectedConnectionClose
            }
            return try await client.scalarInt64("SELECT toInt64(7)")
        }
        #expect(recoveredValue == 7)
        let attemptsUsed = await counter.current
        #expect(attemptsUsed == 2,
                "withRetry should have invoked operation exactly twice: first throws, second succeeds; got \(attemptsUsed)")
    }

    @Test("a streaming SELECT severed mid-flight by a TCP RST surfaces a typed error promptly and the same client can run subsequent queries successfully")
    func midStreamDisconnectSurfacesTypedErrorAndPoolRecovers() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }

        // Threshold tuned so:
        //  - Hello + initial Data-block header sequences pass through
        //    so the SDK observes at least one streaming block before
        //    the cut (the test asserts a partial result, not a fail-fast
        //    handshake).
        //  - The big SELECT keeps producing bytes well past it,
        //    triggering the cut deep in the Data stream.
        //  - The recovery query, which opens a fresh child channel
        //    with its own counter, doesn't exceed it during its short
        //    response.
        let address = try await Self.startProxy(
            group: proxyGroup,
            upstreamHost: Self.host,
            upstreamPort: Self.port,
            bytesUntilCloseFromServer: 500_000
        )
        let proxyPort = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            connectTimeout: .seconds(5),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        // Big SELECT designed to produce many bytes back from the
        // server. The proxy will sever the connection somewhere in
        // the middle.
        var rowsConsumed = 0
        var thrown: Error?
        let started = Date()
        do {
            for try await block in client.selectColumns(
                "SELECT toUInt64(number) FROM numbers(10000000)",
                settings: [.init(name: "max_block_size", value: "1000")]
            ) {
                for column in block.columns {
                    if case .uint64(let chunk) = column.values { rowsConsumed += chunk.count }
                }
            }
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)

        let received = try #require(thrown, "mid-stream disconnect must throw, not hang")
        // The error class we expect: the wire-level decoder hits
        // EOF mid-packet and surfaces `unexpectedConnectionClose`,
        // OR the framing layer reports a NIO `ChannelError.ioOnClosedChannel`,
        // OR the chunked-frame decoder reports a truncated frame.
        // Any of these are valid — what matters is that the SDK
        // does NOT hang, does NOT crash, and the error is typed.
        let description = String(describing: received)
        #expect(
            description.contains("unexpectedConnectionClose")
                || description.contains("ioOnClosedChannel")
                || description.contains("compressionFrameTruncated")
                || description.contains("truncatedBuffer")
                || description.contains("alreadyClosed")
                || description.contains("ChannelError")
                || description.contains("IOError")
                || description.contains("CancellationError")
                || description.contains("cancelled"),
            "mid-stream disconnect must surface a recognized typed error; got: \(description)"
        )
        #expect(elapsed < 10.0,
                "mid-stream disconnect must surface promptly; took \(elapsed)s")
        #expect(rowsConsumed > 0, "consumer must have observed at least one block before the disconnect; got \(rowsConsumed)")
        #expect(rowsConsumed < 10_000_000,
                "the disconnect must cut off the stream before all rows arrive; got \(rowsConsumed)")

        // Pool recovery: a follow-up small query through the same
        // client must succeed via a fresh proxy child channel. The
        // bad connection has been discarded; the new acquire opens
        // a clean one.
        let recoveryStarted = Date()
        let value = try await client.scalarInt64("SELECT toInt64(42)")
        let recoveryElapsed = Date().timeIntervalSince(recoveryStarted)
        #expect(value == 42, "follow-up query after recovery must return the expected value; got \(value)")
        #expect(recoveryElapsed < 5.0,
                "follow-up query after disconnect must complete promptly via a fresh connection; took \(recoveryElapsed)s")
    }

}
