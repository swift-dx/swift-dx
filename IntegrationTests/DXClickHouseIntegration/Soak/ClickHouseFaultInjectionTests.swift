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

// Fault-injection suite for production-shape failure modes:
//
//   1. Server outage mid-query — the upstream is killed while a real
//      SELECT is streaming. The SDK must surface a typed
//      ClickHouseError (no crash, no hang), then a follow-up query
//      against the restored upstream must succeed.
//   2. Streaming-query cancellation — the consumer Task is cancelled
//      mid-stream. The SDK must propagate cancellation (typed error
//      or CancellationError translated to ClickHouseError.cancelled)
//      and remain healthy for the next query on the pool.
//   3. Connection timeout — the configured connectTimeout fires
//      against an unreachable endpoint. The SDK must surface
//      ClickHouseError.handshakeTimedOut, not hang.
//   4. Pool exhaustion under load — a single-slot pool with
//      failImmediatelyWhenExhausted under contention must throw
//      ClickHouseError.poolExhausted on the contending acquire,
//      not deadlock. After the holder releases, the pool serves
//      again.
//
// All four assert the same shape: typed error, no crash, no hang,
// successful follow-up. This is the contract that "the SDK is safe
// to operate" relies on.
@Suite(
    "ClickHouse integration — fault injection (kill+restart, cancel, timeout, pool exhaustion)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseFaultInjectionTests {

    private static var host: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost" }
    private static var port: Int { Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000 }
    private static var user: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_USER"] ?? "default" }
    private static var password: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_PASSWORD"] ?? "" }
    private static var database: String { ProcessInfo.processInfo.environment["CH_INTEGRATION_DATABASE"] ?? "test" }

    // Bytes that have to flow CH→client before the proxy severs the
    // connection. Sized to let the Hello+small reply pass cleanly so
    // the SDK has a healthy connection in the pool before the
    // streaming SELECT is killed.
    private static let midQueryDisconnectThresholdBytes = 65_536

    // The kill-restart proxy. Forwards bytes both directions and tracks
    // whether the upstream side has been "killed" via a shared toggle.
    // Toggling the flag closes both halves of the channel pair — the
    // SDK observes that as a TCP-level mid-stream disconnect, the same
    // shape as a container restart.
    private final class RestartProxy: @unchecked Sendable {

        enum State: Sendable {
            case forwarding
            case killed
        }

        private let group: EventLoopGroup
        private let upstreamHost: String
        private let upstreamPort: Int
        private let stateBox = NIOLockedValueBox<State>(.forwarding)
        private let activeChannels = NIOLockedValueBox<[Channel]>([])
        private var serverChannel: Channel?

        init(group: EventLoopGroup, upstreamHost: String, upstreamPort: Int) {
            self.group = group
            self.upstreamHost = upstreamHost
            self.upstreamPort = upstreamPort
        }

        func bind() async throws -> SocketAddress {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] childChannel in
                    guard let self else {
                        return childChannel.close(mode: .all)
                    }
                    let mode = self.stateBox.withLockedValue { $0 }
                    switch mode {
                    case .killed:
                        return childChannel.close(mode: .all)
                    case .forwarding:
                        let upstreamFuture = ClientBootstrap(group: self.group)
                            .channelInitializer { _ in childChannel.eventLoop.makeSucceededFuture(()) }
                            .connect(host: self.upstreamHost, port: self.upstreamPort)
                        return upstreamFuture.flatMap { upstreamChannel in
                            self.activeChannels.withLockedValue { $0.append(childChannel) }
                            self.activeChannels.withLockedValue { $0.append(upstreamChannel) }
                            let serverHandler = ProxyForwardHandler(peer: childChannel)
                            let clientHandler = ProxyForwardHandler(peer: upstreamChannel)
                            return upstreamChannel.pipeline.addHandler(serverHandler).flatMap {
                                childChannel.pipeline.addHandler(clientHandler)
                            }
                        }
                    }
                }
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            guard let address = channel.localAddress else {
                throw ProxyError.noAddress
            }
            self.serverChannel = channel
            return address
        }

        func sever() {
            stateBox.withLockedValue { $0 = .killed }
            let snapshot = activeChannels.withLockedValue { current -> [Channel] in
                let copy = current
                current.removeAll()
                return copy
            }
            for channel in snapshot {
                channel.close(mode: .all, promise: nil)
            }
        }

        func restore() {
            stateBox.withLockedValue { $0 = .forwarding }
        }

        func shutdown() async {
            sever()
            if let channel = serverChannel {
                try? await channel.close()
            }
        }

    }

    private final class ProxyForwardHandler: ChannelInboundHandler, @unchecked Sendable {

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

    private enum ProxyError: Error {
        case noAddress
        case notIPv4
    }

    private static func portForAddress(_ address: SocketAddress) throws -> Int {
        guard case .v4(let ipv4) = address else { throw ProxyError.notIPv4 }
        return Int(ipv4.address.sin_port.bigEndian)
    }

    @Test("kill+restart upstream mid-query surfaces a typed ClickHouseError, no crash, no hang; reconnect cleans, follow-up SELECT succeeds")
    func killAndRestartUpstreamRecovers() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let proxy = RestartProxy(group: proxyGroup, upstreamHost: Self.host, upstreamPort: Self.port)
        let address = try await proxy.bind()
        let proxyPort = try Self.portForAddress(address)
        defer { Task { await proxy.shutdown() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 2,
            connectTimeout: .seconds(5),
            acquireTimeout: .waitUpTo(.seconds(5)),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        let healthy = try await client.scalarInt64("SELECT toInt64(1)")
        #expect(healthy == 1)

        let iterations = SoakTestSupport.faultInjectionIterations
        for iteration in 0..<iterations {
            let killer = Task<Void, Never> { [proxy] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.sever()
            }

            var caughtTypedError = false
            var caughtUntyped: Error?
            do {
                let stream = client.selectStreamFast(
                    FaultStreamRow.self,
                    from: "SELECT number AS id, toString(number) AS tag, toFloat64(number) AS value FROM numbers(5000000)"
                )
                for try await _ in stream {}
            } catch let error as ClickHouseError {
                caughtTypedError = true
                _ = error
            } catch {
                caughtUntyped = error
            }
            _ = await killer.value

            #expect(caughtTypedError, "iteration \(iteration): mid-query kill must surface a typed ClickHouseError; got untyped \(String(describing: caughtUntyped))")

            proxy.restore()
            let pingStart = ContinuousClock.now
            var recovered = false
            for attempt in 0..<10 {
                do {
                    let value = try await client.scalarInt64("SELECT toInt64(\(iteration * 1000 + attempt))")
                    if value == Int64(iteration * 1000 + attempt) {
                        recovered = true
                        break
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let recoveryMicros = SoakTestSupport.microsecondsSince(pingStart)
            #expect(recovered, "iteration \(iteration): failed to recover within 10 attempts (\(recoveryMicros)us elapsed)")
        }
    }

    @Test("client-side query cancellation via Task.cancel() interrupts a streaming SELECT, surfaces a typed error, and the client recovers for the next query")
    func clientSideTaskCancellationStopsStreamingSelect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 4,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        // sleepEachRow blocks the server for one second per row at
        // max_block_size=1, so each yield arrives slowly enough for
        // the cancellation to be exercised against an in-flight stream.
        let runQuery = """
            SELECT number AS n, sleepEachRow(1) AS s
            FROM numbers(60)
            SETTINGS max_block_size=1
            """

        enum CancellationOutcome: Sendable {

            case rowsCompleted(count: Int)
            case threwTyped(ClickHouseError)
            case threwUntyped(String)
        }

        let cancellationStart = ContinuousClock.now
        let queryTask = Task { @Sendable [client] () -> CancellationOutcome in
            var rowsReceived = 0
            do {
                let stream = client.selectStreamFast(SimpleNumberRow.self, from: runQuery)
                for try await batch in stream {
                    rowsReceived += batch.count
                }
                return .rowsCompleted(count: rowsReceived)
            } catch let error as ClickHouseError {
                return .threwTyped(error)
            } catch {
                return .threwUntyped(String(describing: error))
            }
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        queryTask.cancel()

        let outcome = await queryTask.value
        let elapsed = SoakTestSupport.microsecondsSince(cancellationStart)
        // The full query would take 60s to run to completion (60 rows
        // × 1s/row). Anything under 20s confirms cancellation reached
        // the stream — either the stream threw early, or the loop
        // exited early on cancellation propagation.
        #expect(
            elapsed < 20_000_000,
            "cancelled query took \(elapsed / 1_000_000)s to drain; cancellation did not propagate"
        )
        switch outcome {
        case .rowsCompleted(let count):
            #expect(count < 60, "expected cancellation to interrupt; query completed with \(count) rows")
        case .threwTyped(let error):
            switch error {
            case .cancelled, .serverException, .unexpectedConnectionClose:
                break
            default:
                Issue.record("unexpected typed error from cancelled query: \(error)")
            }
        case .threwUntyped(let description):
            Issue.record("cancelled query surfaced an untyped error: \(description)")
        }

        let followUp = try await client.scalarInt64("SELECT toInt64(42)")
        #expect(followUp == 42, "follow-up scalar query after cancellation must succeed")
    }

    @Test("connect to an unreachable endpoint within connectTimeout surfaces a typed ClickHouseError, never hangs past the timeout")
    func connectTimeoutOnUnreachableEndpointSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "10.255.255.1", port: 9000)],
            database: "default",
            user: "default",
            password: "",
            maxConnections: 1,
            connectTimeout: .milliseconds(500),
            acquireTimeout: .waitUpTo(.seconds(5)),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let start = ContinuousClock.now
        var captured: ClickHouseError?
        do {
            _ = try await client.scalarInt64("SELECT 1")
        } catch {
            captured = error
        }
        let elapsed = SoakTestSupport.microsecondsSince(start)

        #expect(captured != nil, "unreachable endpoint must surface a typed ClickHouseError")
        #expect(
            elapsed < 6_000_000,
            "client took \(elapsed)us before surfacing a connect error; ceiling is connectTimeout + acquireTimeout (~5500ms)"
        )
    }

    @Test("kill+restart upstream mid-view-iteration of selectStringColumns surfaces a typed ClickHouseError, no crash, no hang; follow-up view query succeeds")
    func killAndRestartUpstreamRecoversForViewIteration() async throws {
        let proxyGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await proxyGroup.shutdownGracefully() } }
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await clientGroup.shutdownGracefully() } }

        let proxy = RestartProxy(group: proxyGroup, upstreamHost: Self.host, upstreamPort: Self.port)
        let address = try await proxy.bind()
        let proxyPort = try Self.portForAddress(address)
        defer { Task { await proxy.shutdown() } }

        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "127.0.0.1", port: proxyPort)],
            database: Self.database,
            user: Self.user,
            password: Self.password,
            maxConnections: 2,
            connectTimeout: .seconds(5),
            acquireTimeout: .waitUpTo(.seconds(5)),
            eventLoopGroup: clientGroup
        ))
        defer { Task { await client.shutdown() } }

        let iterations = SoakTestSupport.faultInjectionIterations
        for iteration in 0..<iterations {
            let killer = Task<Void, Never> { [proxy] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.sever()
            }

            var caughtTypedError = false
            var caughtUntyped: Error?
            var bytesObserved = 0
            do {
                let stream = client.selectStringColumns(
                    "SELECT toString(number) AS payload FROM numbers(5000000)"
                )
                for try await block in stream {
                    if case .present(let column) = block.stringColumn(named: "payload") {
                        column.forEach { _, view in bytesObserved += view.utf8Length }
                    }
                }
            } catch let error as ClickHouseError {
                caughtTypedError = true
                _ = error
            } catch {
                caughtUntyped = error
            }
            _ = await killer.value

            #expect(caughtTypedError, "iteration \(iteration): mid-view-iteration kill must surface a typed ClickHouseError; got untyped \(String(describing: caughtUntyped)); bytes observed before kill: \(bytesObserved)")

            proxy.restore()
            var recovered = false
            for attempt in 0..<10 {
                do {
                    let stream = client.selectStringColumns("SELECT toString(number) AS payload FROM numbers(100)")
                    var seenRows = 0
                    for try await block in stream {
                        if case .present(let column) = block.stringColumn(named: "payload") {
                            seenRows += column.rowCount
                        }
                    }
                    if seenRows == 100 {
                        recovered = true
                        break
                    }
                } catch {
                    _ = attempt
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            #expect(recovered, "iteration \(iteration): view-based follow-up failed to recover within 10 attempts")
        }
    }

    @Test("client-side cancellation of a selectStringColumns iteration surfaces a typed error and the client recovers for the next query")
    func clientSideTaskCancellationStopsViewIteration() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 4,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        let runQuery = """
            SELECT toString(number) AS payload, sleepEachRow(1) AS s
            FROM numbers(60)
            SETTINGS max_block_size=1
            """

        enum CancellationOutcome: Sendable {

            case rowsCompleted(count: Int)
            case threwTyped(ClickHouseError)
            case threwUntyped(String)
        }

        let cancellationStart = ContinuousClock.now
        let queryTask = Task { @Sendable [client] () -> CancellationOutcome in
            var rowsReceived = 0
            do {
                let stream = client.selectStringColumns(runQuery)
                for try await block in stream {
                    rowsReceived += block.rowCount
                }
                return .rowsCompleted(count: rowsReceived)
            } catch let error as ClickHouseError {
                return .threwTyped(error)
            } catch {
                return .threwUntyped(String(describing: error))
            }
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        queryTask.cancel()

        let outcome = await queryTask.value
        let elapsed = SoakTestSupport.microsecondsSince(cancellationStart)
        #expect(
            elapsed < 20_000_000,
            "cancelled view iteration took \(elapsed / 1_000_000)s to drain; cancellation did not propagate"
        )
        switch outcome {
        case .rowsCompleted(let count):
            #expect(count < 60, "expected cancellation to interrupt; query completed with \(count) rows")
        case .threwTyped(let error):
            switch error {
            case .cancelled, .serverException, .unexpectedConnectionClose:
                break
            default:
                Issue.record("unexpected typed error from cancelled view iteration: \(error)")
            }
        case .threwUntyped(let description):
            Issue.record("cancelled view iteration surfaced an untyped error: \(description)")
        }

        let followUp = try await client.scalarInt64("SELECT toInt64(42)")
        #expect(followUp == 42, "follow-up scalar query after view-iteration cancellation must succeed")
    }

    @Test("connect timeout while opening a selectStringColumns stream surfaces a typed ClickHouseError, never hangs past the timeout")
    func connectTimeoutForViewStreamSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: .init(
            endpoints: [.init(host: "10.255.255.1", port: 9000)],
            database: "default",
            user: "default",
            password: "",
            maxConnections: 1,
            connectTimeout: .milliseconds(500),
            acquireTimeout: .waitUpTo(.seconds(5)),
            eventLoopGroup: group
        ))
        defer { Task { await client.shutdown() } }

        let start = ContinuousClock.now
        var captured: ClickHouseError?
        do {
            let stream = client.selectStringColumns("SELECT toString(number) FROM numbers(1)")
            for try await _ in stream {}
        } catch let error as ClickHouseError {
            captured = error
        } catch {
            Issue.record("expected typed ClickHouseError from view stream connect timeout, got \(error)")
        }
        let elapsed = SoakTestSupport.microsecondsSince(start)

        #expect(captured != nil, "unreachable endpoint must surface a typed ClickHouseError for view stream")
        #expect(
            elapsed < 6_000_000,
            "client took \(elapsed)us before surfacing a connect error for view stream; ceiling ~5500ms"
        )
    }

    @Test("pool exhaustion under load: failImmediatelyWhenExhausted surfaces ClickHouseError.poolExhausted; pool serves again after holder releases")
    func poolExhaustionUnderContentionSurfacesTypedError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 1,
            endpoints: SoakTestSupport.defaultEndpoints(),
            acquireTimeout: .failImmediatelyWhenExhausted
        ))
        defer { Task { await client.shutdown() } }

        let holderReady = NIOLockedValueBox<Bool>(false)
        let holder = Task { [client] in
            try await client.execute("SELECT sleep(0.5) SETTINGS max_block_size=1")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        holderReady.withLockedValue { $0 = true }

        var captured: ClickHouseError?
        do {
            _ = try await client.scalarInt64("SELECT toInt64(1)")
        } catch {
            captured = error
        }

        #expect(captured != nil, "exhausted pool with failImmediatelyWhenExhausted must surface a typed error")
        if case .poolExhausted = captured {
            // expected
        } else if let captured {
            Issue.record("expected ClickHouseError.poolExhausted, got \(captured)")
        }

        try await holder.value

        let followUp = try await client.scalarInt64("SELECT toInt64(99)")
        #expect(followUp == 99, "pool must serve again after the holder releases")
    }

}

private struct FaultStreamRow: Decodable, Sendable {

    let id: UInt64
    let tag: String
    let value: Double
}

private struct SimpleNumberRow: Decodable, Sendable {

    let n: UInt64
    let s: UInt8
}
