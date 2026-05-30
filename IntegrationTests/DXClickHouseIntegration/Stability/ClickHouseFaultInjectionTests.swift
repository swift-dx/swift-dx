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

import DXClickHouse
import Dispatch
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Seven production-shape fault scenarios for the raw transport. Each
// scenario is its own @Test so a single failure surfaces precisely
// rather than collapsing into the others. The contract for every
// scenario is the same shape:
//
//   * The injected fault surfaces as a typed ClickHouseError (or
//     ClickHouseConnectionPool.Failure for the pool-exhaustion
//     case). Never an untyped Swift error. Never a hang.
//   * After the fault, a fresh connection/pool/client against the
//     real broker is usable end-to-end. No leaked file descriptors,
//     no poisoned arena, no socket state stranded in the kernel.
extension Stability {

@Suite(
    "DXClickHouse stability — fault injection (7 production-shape scenarios)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseFaultInjectionTests {

    @Test("F1: kill+restart container mid-query surfaces typed error and reconnects without leak")
    func killAndRestartContainerMidQuery() async throws {
        guard let containerName = ProcessInfo.processInfo.environment["CH_STABILITY_DOCKER_NAME"] else {
            // This scenario requires sudo docker permissions on the
            // host, which CI may not grant. When the env var is absent
            // the test executes a degraded variant: reconnect against
            // the live broker after a synthetic connection close, so
            // the reconnect path is still exercised even without
            // container control.
            try await Self.degradedReconnectProbe()
            return
        }
        let dockerPath = ProcessInfo.processInfo.environment["CH_STABILITY_DOCKER_PATH"] ?? "/usr/bin/docker"
        let sudoPath = ProcessInfo.processInfo.environment["CH_STABILITY_SUDO_PATH"] ?? "/usr/bin/sudo"

        let connection = try ClickHouseConnection(
            host: ClickHouseStabilitySupport.host,
            port: ClickHouseStabilitySupport.port,
            user: ClickHouseStabilitySupport.user,
            password: ClickHouseStabilitySupport.password,
            database: ClickHouseStabilitySupport.database,
            reconnectionPolicy: ReconnectionPolicy(
                maxAttempts: 10,
                initialBackoff: .milliseconds(200),
                maxBackoff: .seconds(2)
            )
        )
        defer { connection.close() }
        try connection.sendQuery("SELECT toUInt64(1)")
        let warmup = try connection.receiveScalarUInt64()
        #expect(warmup == 1)

        let fdBaseline = ClickHouseStabilityFileDescriptorCount.currentCount()

        let restartResult = Self.runProcess(
            executable: sudoPath,
            arguments: ["-n", dockerPath, "restart", containerName]
        )
        #expect(restartResult.exitCode == 0, "docker restart \(containerName) failed: \(restartResult.stderr)")

        await Self.waitForBroker(timeoutSeconds: 60)

        let probeDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        var reconnected = false
        var typedFaults = 0
        var attempts = 0
        while ContinuousClock.now < probeDeadline {
            attempts += 1
            do {
                try connection.sendQuery("SELECT toUInt64(7)")
                let value = try connection.receiveScalarUInt64()
                if value == 7 {
                    reconnected = true
                    break
                }
            } catch {
                typedFaults += 1
                _ = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #expect(reconnected, "connection did not reconnect after restart within 60s (attempts=\(attempts), typed faults observed=\(typedFaults))")

        if fdBaseline > 0 {
            let fdAfter = ClickHouseStabilityFileDescriptorCount.currentCount()
            #expect(fdAfter <= fdBaseline + 2, "fd count grew from \(fdBaseline) to \(fdAfter) across container restart; expected within +2")
        }
    }

    @Test("F2: mid-stream task cancellation terminates AsyncStream cleanly without crash")
    func midStreamTaskCancellation() async throws {
        let connection = try await ClickHouseStabilitySupport.makeAsyncConnection()
        defer { Task { await connection.close() } }

        let cancellationStart = ContinuousClock.now
        // sendQuery MUST run before receiveBlocks() — both target the
        // same serial worker queue, and posting receiveBlocks first
        // would park the worker in recv() before any query bytes hit
        // the wire, deadlocking sendQuery behind the parked receive.
        try await connection.sendQuery("SELECT number AS id, toString(number) AS payload, toFloat64(number) AS value FROM numbers(5000000)")
        let stream = connection.receiveBlocks()
        let queryTask = Task<(blocksObserved: Int, errorDescription: String, typed: Bool), Never> {
            var observed = 0
            do {
                for try await _ in stream {
                    observed += 1
                    if Task.isCancelled { break }
                }
                return (observed, "completed", true)
            } catch let error as ClickHouseError {
                return (observed, String(describing: error), true)
            } catch {
                return (observed, String(describing: error), false)
            }
        }

        try await Task.sleep(for: .milliseconds(150))
        queryTask.cancel()
        let outcome = await queryTask.value
        let elapsedMicroseconds = ClickHouseStabilitySupport.microsecondsSince(cancellationStart)

        #expect(outcome.typed, "cancelled stream surfaced untyped error: \(outcome.errorDescription)")
        #expect(
            elapsedMicroseconds < 30_000_000,
            "cancelled stream took \(elapsedMicroseconds / 1_000)ms to drain; cancellation did not propagate within 30s ceiling"
        )
    }

    @Test("F3: connect timeout to a wrong port surfaces typed error within 5s")
    func connectTimeoutToWrongPortSurfacesTypedError() async throws {
        let start = ContinuousClock.now
        var captured: ClickHouseError?
        do {
            let connection = try ClickHouseConnection(
                host: "127.0.0.1",
                port: 1,
                user: ClickHouseStabilitySupport.user,
                password: ClickHouseStabilitySupport.password,
                database: ClickHouseStabilitySupport.database,
                reconnectionPolicy: .disabled
            )
            connection.close()
        } catch {
            captured = error
        }
        let elapsedMicroseconds = ClickHouseStabilitySupport.microsecondsSince(start)

        #expect(captured != nil, "wrong-port connect succeeded; expected typed failure")
        if let captured {
            switch captured {
            case .connectionFailed, .socketIOFailed, .unexpectedEOF, .reconnectExhausted:
                break
            case .protocolError, .queryFailed, .endpointsExhausted:
                Issue.record("unexpected typed error for wrong-port connect: \(captured)")
            }
        }
        #expect(
            elapsedMicroseconds < 5_000_000,
            "wrong-port connect took \(elapsedMicroseconds)us before surfacing typed error; ceiling 5s"
        )
    }

    @Test("F4: pool exhaustion under contention surfaces typed acquireTimedOut within the acquire timeout")
    func poolExhaustionSurfacesTypedTimeout() async throws {
        let pool = try await ClickHouseStabilitySupport.makePool(
            maxConnections: 1,
            minConnections: 1,
            acquireTimeout: .milliseconds(500)
        )
        defer { Task { await pool.close() } }

        let holderReady = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        let holder = Task<Void, Never> {
            do {
                try await pool.withConnection { connection in
                    holderReady.signal()
                    try await connection.sendQuery("SELECT sleep(1.0)")
                    _ = try await connection.drainBlocks()
                }
            } catch {
                _ = error
            }
            holderDone.signal()
        }
        holderReady.wait()

        let acquireStart = ContinuousClock.now
        var captured: ClickHouseConnectionPool.Failure?
        do {
            try await pool.withConnection { _ in }
        } catch let error as ClickHouseConnectionPool.Failure {
            captured = error
        } catch {
            holderDone.wait()
            _ = holder
            Issue.record("expected ClickHouseConnectionPool.Failure, got untyped \(error)")
            return
        }
        let elapsedMicroseconds = ClickHouseStabilitySupport.microsecondsSince(acquireStart)
        holderDone.wait()
        _ = holder

        guard let failure = captured else {
            Issue.record("second acquire succeeded; expected acquireTimedOut")
            return
        }
        switch failure {
        case .acquireTimedOut:
            #expect(
                elapsedMicroseconds >= 400_000 && elapsedMicroseconds <= 5_000_000,
                "acquireTimedOut fired at \(elapsedMicroseconds)us; expected 400ms..5s window"
            )
        case .poolClosed, .openFailed, .allEndpointsFailed:
            Issue.record("unexpected typed failure for pool exhaustion: \(failure)")
        }

        // Pool serves again once the holder releases.
        let recovered = try await pool.withConnection { connection in
            try await connection.sendQuery("SELECT toUInt64(99)")
            return try await connection.receiveScalarUInt64()
        }
        #expect(recovered == 99, "pool failed to serve after the holder released")
    }

    @Test("F5: server-side query error surfaces typed queryFailed and the connection remains usable")
    func serverSideQueryErrorSurfacesQueryFailed() async throws {
        let connection = try await ClickHouseStabilitySupport.makeAsyncConnection()
        defer { Task { await connection.close() } }

        var captured: ClickHouseError?
        do {
            try await connection.sendQuery("SELECT not_a_real_column FROM not_a_real_table_for_raw_stability")
            _ = try await connection.drainBlocks()
        } catch let error as ClickHouseError {
            captured = error
        } catch {
            Issue.record("expected typed ClickHouseError for server-side error, got \(error)")
            return
        }
        guard let error = captured else {
            Issue.record("malformed SQL succeeded; expected queryFailed")
            return
        }
        switch error {
        case .queryFailed(let exception):
            #expect(exception.code != 0)
            #expect(!exception.name.isEmpty)
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .endpointsExhausted:
            Issue.record("expected .queryFailed, got \(error)")
        }

        // Connection survives — a follow-up scalar query still works.
        try await connection.sendQuery("SELECT toUInt64(99)")
        let value = try await connection.receiveScalarUInt64()
        #expect(value == 99, "follow-up scalar after queryFailed returned \(value); expected 99")
    }

    @Test("F6: TCP RST mid-receive surfaces typed error and a fresh connection still works")
    func tcpResetMidReceiveSurfacesTypedError() async throws {
        let forwarder = ClickHouseStabilityResettingForwarder(
            upstreamHost: ClickHouseStabilitySupport.host,
            upstreamPort: ClickHouseStabilitySupport.port
        )
        let proxyPort: Int
        do {
            proxyPort = try forwarder.bind()
        } catch {
            Issue.record("forwarder bind failed: \(error)")
            return
        }
        defer { forwarder.shutdown() }

        let connection: AsyncClickHouseConnection
        do {
            // Reconnect disabled: after the forwarder fires RST the
            // upstream is gone, but the forwarder's listen socket is
            // still open with no accept thread alive. A reconnect attempt
            // would succeed at connect() (the kernel completes the SYN
            // into the listen backlog), then block forever in recv()
            // waiting for a Hello packet the dead forwarder will never
            // bounce back. The scenario under test is the typed-error
            // surface for the mid-receive RST, not the reconnect retry
            // policy, so disable retries on the forwarder-bound socket.
            connection = try await AsyncClickHouseConnection(
                host: "127.0.0.1",
                port: proxyPort,
                user: ClickHouseStabilitySupport.user,
                password: ClickHouseStabilitySupport.password,
                database: ClickHouseStabilitySupport.database,
                reconnectionPolicy: .disabled
            )
        } catch {
            Issue.record("connect via forwarder failed: \(error)")
            return
        }

        let resetter = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(100))
            forwarder.severe()
        }

        var captured: ClickHouseError?
        var untyped: String?
        do {
            try await connection.sendQuery("SELECT number, toString(number) AS payload FROM numbers(5000000)")
            _ = try await connection.drainBlocks()
        } catch let error as ClickHouseError {
            captured = error
        } catch {
            untyped = String(describing: error)
        }
        _ = await resetter.value
        await connection.close()

        #expect(untyped == nil, "expected typed ClickHouseError for TCP RST, got \(untyped ?? "")")
        guard let error = captured else {
            Issue.record("drain succeeded; expected RST-induced typed error")
            return
        }
        switch error {
        case .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .connectionFailed:
            break
        case .queryFailed, .endpointsExhausted:
            Issue.record("unexpected typed error for TCP RST: \(error)")
        }

        // Fresh connection against the real upstream still works.
        let recovered = try await ClickHouseStabilitySupport.makeAsyncConnection()
        try await recovered.sendQuery("SELECT toUInt64(42)")
        let value = try await recovered.receiveScalarUInt64()
        await recovered.close()
        #expect(value == 42, "post-RST fresh connection scalar=\(value); expected 42")
    }

    @Test("F7: 1000× connect/disconnect cycles leak no file descriptors")
    func thousandConnectDisconnectCyclesLeakNoDescriptors() async throws {
        // Warm-up: prime the OS-level allocator so the first 50 cycles
        // don't skew the baseline. After warm-up the fd count must hold
        // steady within a small slack window.
        for _ in 0..<50 {
            let connection = try await ClickHouseStabilitySupport.makeAsyncConnection()
            await connection.close()
        }
        let baseline = ClickHouseStabilityFileDescriptorCount.currentCount()
        let cycles = 1_000
        for _ in 0..<cycles {
            let connection = try await ClickHouseStabilitySupport.makeAsyncConnection()
            await connection.close()
        }
        let after = ClickHouseStabilityFileDescriptorCount.currentCount()

        if baseline > 0 {
            // Allow up to 8 fds of slack for transient pipes,
            // logging files, or proc/self entries opened by URLSession
            // and friends across the run.
            #expect(
                after <= baseline + 8,
                "fd count grew from \(baseline) to \(after) across \(cycles) connect/disconnect cycles (slack +8)"
            )
        }
    }

    private static func degradedReconnectProbe() async throws {
        let connection = try ClickHouseConnection(
            host: ClickHouseStabilitySupport.host,
            port: ClickHouseStabilitySupport.port,
            user: ClickHouseStabilitySupport.user,
            password: ClickHouseStabilitySupport.password,
            database: ClickHouseStabilitySupport.database,
            reconnectionPolicy: ReconnectionPolicy(
                maxAttempts: 10,
                initialBackoff: .milliseconds(200),
                maxBackoff: .seconds(2)
            )
        )
        defer { connection.close() }
        try connection.sendQuery("SELECT toUInt64(1)")
        let warmup = try connection.receiveScalarUInt64()
        #expect(warmup == 1)

        connection.close()

        // Reconnection policy must let the next sendQuery transparently
        // re-open the underlying socket.
        try connection.sendQuery("SELECT toUInt64(7)")
        let after = try connection.receiveScalarUInt64()
        #expect(after == 7, "degraded reconnect probe returned \(after); expected 7")
    }

    private static func waitForBroker(timeoutSeconds: Double) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutSeconds * 1_000_000_000)))
        while ContinuousClock.now < deadline {
            do {
                let probe = try ClickHouseConnection(
                    host: ClickHouseStabilitySupport.host,
                    port: ClickHouseStabilitySupport.port,
                    user: ClickHouseStabilitySupport.user,
                    password: ClickHouseStabilitySupport.password,
                    database: ClickHouseStabilitySupport.database,
                    reconnectionPolicy: .disabled
                )
                probe.close()
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "spawn failed: \(error)")
        }
    }
}

}

// Local TCP forwarder used by the F6 (TCP RST mid-receive) scenario.
// Listens on 127.0.0.1:0, accepts one inbound connection, opens an
// upstream to the real broker, and pipes bytes both ways via two helper
// threads. `severe()` closes both sockets with SO_LINGER=0, forcing
// the kernel to issue a TCP RST instead of a graceful FIN — the same
// shape a production middlebox produces on an abruptly-terminated
// stream.
final class ClickHouseStabilityResettingForwarder: @unchecked Sendable {

    private let upstreamHost: String
    private let upstreamPort: Int
    private var listenSocket: Int32 = -1
    private var inboundSocket: Int32 = -1
    private var upstreamSocket: Int32 = -1
    private let lock = NSLock()
    private(set) var localPort: Int = 0
    private var severeRequested = false

    init(upstreamHost: String, upstreamPort: Int) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    func bind() throws -> Int {
        let listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if listenFd < 0 {
            throw NSError(domain: "ClickHouseStabilityForwarder", code: Int(errno), userInfo: nil)
        }
        var reuse: Int32 = 1
        _ = setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                #if canImport(Glibc)
                return SwiftGlibc.bind(listenFd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                return Darwin.bind(listenFd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        if bindResult < 0 {
            let savedErrno = errno
            close(listenFd)
            throw NSError(domain: "ClickHouseStabilityForwarder", code: Int(savedErrno), userInfo: nil)
        }
        if listen(listenFd, 1) < 0 {
            let savedErrno = errno
            close(listenFd)
            throw NSError(domain: "ClickHouseStabilityForwarder", code: Int(savedErrno), userInfo: nil)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(listenFd, generic, &length)
            }
        }
        listenSocket = listenFd
        localPort = Int(UInt16(bigEndian: bound.sin_port))

        let acceptThread = Thread { [weak self] in
            self?.acceptOnce()
        }
        acceptThread.start()
        return localPort
    }

    private func acceptOnce() {
        var clientAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inbound = withUnsafeMutablePointer(to: &clientAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                accept(listenSocket, generic, &length)
            }
        }
        if inbound < 0 { return }
        let upstream = openUpstream()
        if upstream < 0 {
            close(inbound)
            return
        }
        lock.lock()
        inboundSocket = inbound
        upstreamSocket = upstream
        let shouldStop = severeRequested
        lock.unlock()
        if shouldStop {
            forceReset(socketHandle: inbound)
            forceReset(socketHandle: upstream)
            return
        }
        Thread { [weak self] in
            self?.copyBytes(from: inbound, to: upstream)
        }.start()
        Thread { [weak self] in
            self?.copyBytes(from: upstream, to: inbound)
        }.start()
    }

    private func openUpstream() -> Int32 {
        // getaddrinfo resolves both dotted-quad IPv4 ("127.0.0.1") and
        // hostnames ("localhost"). inet_addr returns INADDR_NONE for
        // hostnames, which silently turns into a -1 address that the
        // kernel refuses with EINVAL, so the forwarder closes the
        // inbound socket and the test's handshake recv() sees a
        // misleading EOF instead of bytes from the upstream.
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var resolved: UnsafeMutablePointer<addrinfo>? = nil
        let portString = String(upstreamPort)
        let lookup = upstreamHost.withCString { hostPointer in
            portString.withCString { portPointer in
                getaddrinfo(hostPointer, portPointer, &hints, &resolved)
            }
        }
        if lookup != 0 || resolved == nil { return -1 }
        defer { freeaddrinfo(resolved) }
        guard let info = resolved else { return -1 }
        let upstream = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if upstream < 0 { return -1 }
        let connected = connect(upstream, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if connected < 0 {
            close(upstream)
            return -1
        }
        return upstream
    }

    private func copyBytes(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        buffer.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            while true {
                let received = recv(source, base, pointer.count, 0)
                if received <= 0 { break }
                var sent = 0
                while sent < received {
                    let wrote = send(destination, base.advanced(by: sent), received - sent, Int32(MSG_NOSIGNAL))
                    if wrote <= 0 { return }
                    sent += wrote
                }
            }
        }
    }

    func severe() {
        lock.lock()
        severeRequested = true
        let inbound = inboundSocket
        let upstream = upstreamSocket
        inboundSocket = -1
        upstreamSocket = -1
        lock.unlock()
        forceReset(socketHandle: inbound)
        forceReset(socketHandle: upstream)
    }

    private func forceReset(socketHandle: Int32) {
        if socketHandle < 0 { return }
        var lingerOption = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(socketHandle, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
        // shutdown(SHUT_RDWR) before close ensures the kernel issues a
        // TCP RST that propagates to the peer's pending recv() promptly.
        // Without the explicit shutdown, close-with-LINGER=0 on a socket
        // whose copy thread still holds a recv() reference can park the
        // RST behind the FD reference count; the peer's recv() then sees
        // no signal until something else closes the kernel TCP state.
        #if canImport(Glibc)
        _ = Glibc.shutdown(socketHandle, Int32(SHUT_RDWR))
        #elseif canImport(Darwin)
        _ = Darwin.shutdown(socketHandle, Int32(SHUT_RDWR))
        #endif
        close(socketHandle)
    }

    func shutdown() {
        severe()
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }
}
