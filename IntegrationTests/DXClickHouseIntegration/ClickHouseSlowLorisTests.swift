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
import NIOCore
import NIOPosix
import Testing

// End-to-end deadline coverage against a silent peer. Spins up a tiny
// NIO ServerBootstrap that accepts TCP and never sends anything, then
// points a ClickHouseClient at it with a short connectTimeout. The
// post-connect deadline (covering Hello roundtrip + addendum write +
// pipeline swap) must fire promptly with `handshakeTimedOut`, not
// hang. This is the most realistic possible test of the deadline
// because it exercises the actual NIO pipeline against a real socket
// rather than mocking the receiver.
@Suite("ClickHouse integration — slow-loris deadline", .serialized)
struct ClickHouseSlowLorisTests {

    // ChannelInitializer that adds a handler which silently swallows
    // every inbound byte. Accepts the connection (so TCP succeeds) but
    // never writes anything back, simulating a server that has stopped
    // making forward progress.
    private final class SilentHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer
        // No-op channelRead — we just consume the bytes and stay quiet.

    }

    // Writes `prefix` once on the first inbound byte we receive (so the
    // client has a chance to start its handshake), then goes silent.
    // Simulates a server that begins replying but stalls mid-Hello.
    private final class PartialReplyHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer

        private let prefix: ByteBuffer
        private var hasReplied = false

        init(prefix: ByteBuffer) {
            self.prefix = prefix
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !hasReplied else { return }
            hasReplied = true
            var copy = prefix
            context.writeAndFlush(NIOAny(IOData.byteBuffer(copy.readSlice(length: copy.readableBytes) ?? ByteBuffer())), promise: nil)
        }

    }

    // Writes `garbage` bytes once then closes — simulates a server
    // that responds with malformed bytes that the handshake decoder
    // can't parse.
    private final class GarbageReplyHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer

        private let garbage: ByteBuffer
        private var hasReplied = false

        init(garbage: ByteBuffer) {
            self.garbage = garbage
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !hasReplied else { return }
            hasReplied = true
            var copy = garbage
            context.writeAndFlush(NIOAny(IOData.byteBuffer(copy.readSlice(length: copy.readableBytes) ?? ByteBuffer())), promise: nil)
        }

    }

    // Writes a configurable prefix on the first inbound byte then
    // closes the channel. Simulates a server that gets some way
    // through a reply and then drops the connection (process crash,
    // load balancer eviction, etc.).
    private final class WriteThenCloseHandler: ChannelInboundHandler, @unchecked Sendable {

        typealias InboundIn = ByteBuffer

        private let prefix: ByteBuffer
        private var hasReplied = false

        init(prefix: ByteBuffer) {
            self.prefix = prefix
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !hasReplied else { return }
            hasReplied = true
            var copy = prefix
            let buffer = copy.readSlice(length: copy.readableBytes) ?? ByteBuffer()
            let writeFuture = context.writeAndFlush(NIOAny(IOData.byteBuffer(buffer)))
            writeFuture.whenComplete { _ in
                context.close(promise: nil)
            }
        }

    }

    private static func startSilentServer(group: EventLoopGroup) async throws -> SocketAddress {
        try await Self.startServer(group: group) { channel in
            channel.pipeline.addHandler(SilentHandler())
        }
    }

    private static func startPartialReplyServer(
        group: EventLoopGroup,
        prefix: ByteBuffer
    ) async throws -> SocketAddress {
        try await Self.startServer(group: group) { channel in
            channel.pipeline.addHandler(PartialReplyHandler(prefix: prefix))
        }
    }

    private static func startGarbageServer(
        group: EventLoopGroup,
        garbage: ByteBuffer
    ) async throws -> SocketAddress {
        try await Self.startServer(group: group) { channel in
            channel.pipeline.addHandler(GarbageReplyHandler(garbage: garbage))
        }
    }

    private static func startWriteThenCloseServer(
        group: EventLoopGroup,
        prefix: ByteBuffer
    ) async throws -> SocketAddress {
        try await Self.startServer(group: group) { channel in
            channel.pipeline.addHandler(WriteThenCloseHandler(prefix: prefix))
        }
    }

    private static func startServer(
        group: EventLoopGroup,
        initialiser: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> SocketAddress {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer(initialiser)
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let address = channel.localAddress else {
            throw SilentServerError.noAddress
        }
        return address
    }

    private static func portForAddress(_ address: SocketAddress) throws -> Int {
        guard case .v4(let ipv4) = address else {
            throw SilentServerError.notIPv4
        }
        return Int(ipv4.address.sin_port.bigEndian)
    }

    private enum SilentServerError: Error {

        case noAddress
        case notIPv4

    }

    @Test("post-connect deadline fires within the configured window when the server never sends Hello")
    func deadlineFiresAgainstSilentServer() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        let address = try await Self.startSilentServer(group: serverGroup)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .milliseconds(300),
            eventLoopGroup: clientGroup
        ))

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        let received = try #require(thrown, "client must throw against a silent server, not hang")

        // The pool wraps the connect failure in `allPoolEndpointsFailed`.
        // The underlying cause must be the handshake timeout — that's
        // the contract that proves the post-connect deadline fired
        // (rather than something like an OS-level socket timeout, which
        // would take much longer).
        let lastError: String
        if case ClickHouseError.allPoolEndpointsFailed(let inner) = received {
            lastError = inner ?? ""
        } else {
            lastError = String(describing: received)
        }
        #expect(lastError.contains("handshakeTimedOut"),
                "expected handshakeTimedOut as the underlying cause; got: \(lastError)")
        #expect(elapsed < 1.0,
                "deadline should fire near the configured 300 ms; observed \(elapsed)s")
    }

    @Test("repeated connects against a silent server all fail promptly without leaking pool slots")
    func deadlineFiresRepeatedlyOnSilentServer() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        let address = try await Self.startSilentServer(group: serverGroup)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .milliseconds(150),
            eventLoopGroup: clientGroup
        ))

        // Five sequential attempts each must surface a typed error
        // within the deadline window; the pool must NOT accumulate
        // half-open connections that would tie up subsequent retries.
        let started = Date()
        for _ in 0..<5 {
            do {
                _ = try await client.scalarInt64("SELECT toInt64(1)")
                Issue.record("each attempt against the silent server must throw")
            } catch {
                continue
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        // 5 × 150 ms = 750 ms ideal; allow generous slack for connect
        // overhead. If the deadline weren't firing, the OS-level socket
        // timeout would push this well over a minute.
        #expect(elapsed < 5.0, "5 silent-server attempts should complete in well under 5s; observed \(elapsed)s")
    }

    @Test(
        "post-connect deadline fires regardless of how far into the Hello the server got before stalling",
        arguments: [1, 5, 10, 20, 40] as [Int]
    )
    func deadlineFiresOnProgressivePartialHello(prefixLength: Int) async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Build a buffer that LOOKS like a server Hello of plausible
        // size (60+ bytes) but only emit the first `prefixLength`
        // bytes. The decoder will accept the partial bytes, set up
        // its accumulator, and wait for more — which never come. The
        // deadline must fire regardless of the exact partial length.
        var fullHello = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &fullHello)
        fullHello.writeClickHouseString("ClickHouse")
        fullHello.writeClickHouseUVarInt(24)   // versionMajor
        fullHello.writeClickHouseUVarInt(8)    // versionMinor
        fullHello.writeClickHouseUVarInt(54_478) // serverRevision
        fullHello.writeClickHouseString("UTC")
        fullHello.writeClickHouseString("ch-test-1")
        fullHello.writeClickHouseUVarInt(0)    // versionPatch
        let totalAvailable = fullHello.readableBytes
        let actualLength = min(prefixLength, totalAvailable)
        let prefix = fullHello.readSlice(length: actualLength) ?? ByteBuffer()

        let address = try await Self.startPartialReplyServer(group: serverGroup, prefix: prefix)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .milliseconds(300),
            eventLoopGroup: clientGroup
        ))

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        let received = try #require(thrown,
                                    "prefix=\(actualLength): client must throw, not hang")
        guard received is ClickHouseError else {
            Issue.record("prefix=\(actualLength): expected ClickHouseError, got \(received)")
            return
        }
        #expect(elapsed < 1.0,
                "prefix=\(actualLength): deadline should fire near 300 ms; observed \(elapsed)s")
    }

    @Test("post-connect deadline fires when the server starts a Hello reply but stalls partway through")
    func deadlineFiresOnPartialHello() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Send the Hello packet-type marker (1 byte) then go silent.
        // Production decoders must wait for more bytes after the
        // marker, but with no follow-up they will hang. The deadline
        // must still fire.
        var prefix = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &prefix)
        let address = try await Self.startPartialReplyServer(group: serverGroup, prefix: prefix)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .milliseconds(300),
            eventLoopGroup: clientGroup
        ))

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        let received = try #require(thrown, "client must throw against a partial-Hello server, not hang")
        let lastError: String
        if case ClickHouseError.allPoolEndpointsFailed(let inner) = received {
            lastError = inner ?? ""
        } else {
            lastError = String(describing: received)
        }
        #expect(lastError.contains("handshakeTimedOut"),
                "expected handshakeTimedOut underlying cause; got: \(lastError)")
        #expect(elapsed < 1.0, "deadline should fire near the configured 300 ms; observed \(elapsed)s")
    }

    @Test("a configuration with empty endpoints array surfaces poolHasNoEndpoints on first acquire (no hang)")
    func emptyEndpointsArraySurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [],
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "empty endpoints must throw on first acquire, not hang")
        guard case ClickHouseError.poolHasNoEndpoints = received else {
            Issue.record("expected poolHasNoEndpoints, got \(received)")
            return
        }
    }

    @Test("a directly-constructed Endpoint with an out-of-range port surfaces a typed error from the connect layer")
    func directEndpointOutOfRangePortSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        // The URL parser rejects ports outside [1, 65535] explicitly.
        // The typed Endpoint init does not — by design, since most
        // callers pass hardcoded ports. But if someone wires a port
        // from runtime input directly into an Endpoint, the failure
        // must still surface as a typed error rather than a hang or
        // crash. The connect layer catches the integer mismatch and
        // throws via `allPoolEndpointsFailed`.
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: 99_999)],
            connectTimeout: .milliseconds(500),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let received = try #require(thrown, "out-of-range port must throw, not hang or crash")
        guard case ClickHouseError.allPoolEndpointsFailed = received else {
            Issue.record("expected allPoolEndpointsFailed, got \(received)")
            return
        }
    }

    @Test("an Endpoint with an unresolvable hostname surfaces allPoolEndpointsFailed promptly")
    func unresolvableHostnameSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        // .invalid is reserved for guaranteed-not-to-resolve hostnames
        // per RFC 6761; the OS-level resolver will reject it cleanly
        // rather than timing out on DNS.
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "definitely-not-a-host.invalid", port: 9000)],
            connectTimeout: .seconds(2),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let received = try #require(thrown, "unresolvable hostname must throw, not hang")
        guard case ClickHouseError.allPoolEndpointsFailed = received else {
            Issue.record("expected allPoolEndpointsFailed, got \(received)")
            return
        }
        // DNS rejection is typically near-instant; the connectTimeout
        // is the safety net.
        #expect(elapsed < 2.5, "DNS rejection should be near-instant; observed \(elapsed)s")
    }

    @Test("warmUp gives up promptly when ALL endpoints are silent — does not loop forever")
    func warmUpThrowsWhenAllEndpointsAreSilent() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Two silent test servers — every acquire times out, every
        // failover walks the full endpoint list, every attempt throws.
        // The contract: warmUp throws on the FIRST failed acquire
        // rather than retrying through all N requested connections
        // (which would multiply the failure latency by N).
        let silent1 = try Self.portForAddress(try await Self.startSilentServer(group: serverGroup))
        let silent2 = try Self.portForAddress(try await Self.startSilentServer(group: serverGroup))

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: "127.0.0.1", port: silent1),
                .init(host: "127.0.0.1", port: silent2),
            ],
            connectTimeout: .milliseconds(200),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        let started = Date()
        var thrown: Error?
        do {
            try await client.warmUp(connections: 5)
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let received = try #require(thrown, "warmUp must throw when all endpoints are silent, not loop")
        guard case ClickHouseError.allPoolEndpointsFailed = received else {
            Issue.record("expected allPoolEndpointsFailed, got \(received)")
            return
        }
        // 2 endpoints × 200 ms deadline = 400 ms ideal for one failed
        // acquire. The contract is "fails on the first", so 5 requested
        // connections must NOT multiply this by 5.
        #expect(elapsed < 1.5,
                "warmUp must throw on the first failed acquire (≤2×deadline), not loop through all N requested; observed \(elapsed)s")
    }

    @Test(
        "warmUp(N) against a mixed pool (silent + live) completes cleanly via failover and warms the live endpoint",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func warmUpThroughMixedEndpoints() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // One silent endpoint plus the live cluster. warmUp(3) must
        // failover past the silent on each acquire and end up with
        // 3 idle connections to the live endpoint. If the failover
        // logic leaked the silent's half-open socket on each attempt,
        // we'd see FD growth proportional to the warmup count.
        let silent = try Self.portForAddress(try await Self.startSilentServer(group: serverGroup))
        let liveHost = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let livePort = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let user = ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
        let database = ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test"

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: "127.0.0.1", port: silent),
                .init(host: liveHost, port: livePort),
            ],
            database: database,
            user: user,
            password: password,
            maxConnections: 5,
            maxIdleConnections: 5,
            // 1500 ms (was 300 ms, flaked under concurrent integration-
            // suite load when the test runner stalled the live
            // handshake past 300 ms). Test asserts a logical property
            // — failover past silent to live completes — not a tight
            // timing behaviour.
            connectTimeout: .milliseconds(1500),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        let started = Date()
        try await client.warmUp(connections: 3)
        let elapsed = Date().timeIntervalSince(started)

        let stats = await client.poolStats()
        #expect(stats.idleCount == 3, "warmUp must populate the idle pool with N connections; got \(stats.idleCount)")
        #expect(stats.totalConnectionsOpened == 3,
                "no extra connection opens (silents must not be counted twice); got \(stats.totalConnectionsOpened)")

        // First acquire against silent -> deadline -> failover. After
        // that, the silent is in cooldown so subsequent warm-up
        // connections go straight to the live endpoint.
        // Bound: 1×1500ms (silent deadline) + 3 quick live connects.
        // Without cooldown skipping, this would be 3×1500ms = 4.5s.
        // 4.0s is well under the without-cooldown floor and gives
        // generous slack for runner load.
        #expect(elapsed < 4.0,
                "warmUp must skip cooldown'd silents on subsequent acquires; observed \(elapsed)s")
    }

    @Test(
        "multi-endpoint failover lands on the live cluster when other endpoints are silent",
        .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
    )
    func multiEndpointFailoverThroughSilents() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Two silent endpoints + the real cluster. The pool's
        // round-robin picker must walk past the silents (each hitting
        // the post-connect deadline), record their failures, and land
        // on the live cluster within a bounded time.
        let silent1 = try Self.portForAddress(try await Self.startSilentServer(group: serverGroup))
        let silent2 = try Self.portForAddress(try await Self.startSilentServer(group: serverGroup))
        let liveHost = ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
        let livePort = Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
        let user = ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default"
        let password = ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? ""
        let database = ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test"

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [
                .init(host: "127.0.0.1", port: silent1),
                .init(host: "127.0.0.1", port: silent2),
                .init(host: liveHost, port: livePort),
            ],
            database: database,
            user: user,
            password: password,
            // 1.5 s connectTimeout: long enough that the LIVE
            // cluster's handshake won't flake under occasional
            // server-side latency spikes (300 ms had been intermittently
            // failing on `handshakeTimedOut` against the live cluster),
            // short enough that the silent-endpoint deadlines still
            // dominate the test wall clock and prove the failover is
            // working.
            connectTimeout: .milliseconds(1500),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        let started = Date()
        let value = try await client.scalarInt64("SELECT toInt64(7)")
        let elapsed = Date().timeIntervalSince(started)

        #expect(value == 7, "must land on the live cluster after walking past silents")
        // 2 × 1.5 s deadline plus live connect overhead. Generous
        // ceiling that still proves the post-connect deadline is
        // firing (without it, this test would exceed a minute).
        #expect(elapsed < 6.0, "failover must complete in under 6s; observed \(elapsed)s")

        // After failover, the silent endpoints should be in cooldown.
        // A second query should go directly to the live cluster
        // without re-attempting the silents.
        let started2 = Date()
        let value2 = try await client.scalarInt64("SELECT toInt64(11)")
        let elapsed2 = Date().timeIntervalSince(started2)
        #expect(value2 == 11)
        #expect(elapsed2 < 1.0, "second query should skip cooldown'd silents and finish quickly; observed \(elapsed2)s")
    }

    @Test("server that writes a marker then closes mid-handshake surfaces a typed error promptly")
    func serverClosesMidHandshakeSurfacesTypedError() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Send the Hello marker (1 byte) then close. The handshake
        // decoder will be waiting for the rest of the Hello body and
        // sees EOF instead. That must surface as a typed error, not
        // hang waiting for more bytes nor be silently treated as
        // success. The deadline is the safety net but should not be
        // the path we hit — close is observable immediately on most
        // platforms.
        var prefix = ByteBuffer()
        ClickHouseServerPacketType.hello.write(into: &prefix)
        let address = try await Self.startWriteThenCloseServer(group: serverGroup, prefix: prefix)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .seconds(2),
            eventLoopGroup: clientGroup
        ))

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        let received = try #require(thrown, "client must throw against a write-then-close server, not hang or succeed")
        guard received is ClickHouseError else {
            Issue.record("expected ClickHouseError, got \(received)")
            return
        }
        // The close-on-EOF path should be observable in a few hundred
        // ms — much faster than the 2 s deadline. If we're hitting the
        // deadline path here, something is wrong with how the
        // handshake decoder handles EOF.
        #expect(elapsed < 1.5,
                "EOF should be detectable promptly without waiting for the deadline; observed \(elapsed)s")
    }

    @Test("malformed Hello reply surfaces a typed protocol error rather than crashing")
    func malformedReplySurfacesTypedError() async throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await serverGroup.shutdownGracefully() } }

        // Garbage: marker byte 0xFF (no such CH server packet type),
        // followed by a malformed UVarInt prefix + arbitrary bytes.
        // Whatever the decoder sees, it must surface as a typed error,
        // never crash or hang.
        var garbage = ByteBuffer()
        garbage.writeBytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF])
        let address = try await Self.startGarbageServer(group: serverGroup, garbage: garbage)
        let port = try Self.portForAddress(address)

        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: port)],
            connectTimeout: .seconds(2),
            eventLoopGroup: clientGroup
        ))

        let started = Date()
        var thrown: Error?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        await client.shutdown()

        let received = try #require(thrown, "client must throw on malformed reply, not hang")
        // Either the codec rejects the garbage (typed protocol error) or
        // the server's premature close fires the post-connect deadline.
        // Both are acceptable contracts; what we care about is that the
        // failure surfaces as a `ClickHouseError` and does so
        // promptly.
        guard received is ClickHouseError else {
            Issue.record("expected ClickHouseError, got \(received)")
            return
        }
        #expect(elapsed < 3.0, "malformed-reply path should not hang; observed \(elapsed)s")
    }

}
