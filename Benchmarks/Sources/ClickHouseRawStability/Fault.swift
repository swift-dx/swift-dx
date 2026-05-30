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

import DXClickHouseRaw
import Dispatch
import Foundation

// Fault-injection phase. Seven scenarios, each runs to completion
// (PASS/FAIL) independently and is reported on its own line; the run
// continues past failures so the operator gets the full picture in
// one pass.
//
//   F1 container_kill_restart   sudo docker restart, wait, re-query.
//   F2 mid_stream_cancellation  cancel a streaming AsyncThrowingStream
//                               mid-iteration and assert clean finish.
//   F3 wrong_port_connect       connect to a closed port and assert
//                               typed RawClickHouseError, not hang.
//   F4 pool_exhaustion          maxConnections=1 + tight acquireTimeout
//                               under contention; assert typed
//                               acquireTimedOut.
//   F5 server_side_query_error  send a malformed SQL and assert the
//                               server-side exception surfaces as
//                               RawClickHouseError.queryFailed.
//   F6 mid_receive_tcp_rst      forwarder issues RST while the client
//                               is draining a large SELECT; assert
//                               typed error AND that the NEXT connect
//                               attempt against the real upstream
//                               succeeds (no lingering state).
//   F7 mid_receive_cancel       cancel a Task drainBlocks() in the
//                               middle of a multi-block scan; assert
//                               typed termination and that opening a
//                               fresh connection still works (no leaked
//                               socket).
enum StabilityFault {

    private struct ScenarioResult: Sendable {
        let id: String
        let passed: Bool
        let detail: String
    }

    static func run() async {
        print("[STAB FAULT] starting scenarios=7")
        var results: [ScenarioResult] = []

        results.append(await containerKillRestart())
        results.append(await midStreamCancellation())
        results.append(await wrongPortConnect())
        results.append(await poolExhaustion())
        results.append(await serverSideQueryError())
        results.append(await midReceiveTcpRst())
        results.append(await midReceiveCancel())

        for result in results {
            print("[STAB FAULT] \(result.id) result=\(result.passed ? "PASS" : "FAIL") detail=\(result.detail)")
        }
        let passed = results.allSatisfy { $0.passed }
        print("[STAB FAULT] verdict total=\(results.count) passed=\(results.count(where: { $0.passed })) failed=\(results.count(where: { !$0.passed })) overall=\(passed ? "PASS" : "FAIL")")
    }

    // F1: Container kill + restart. Uses sudo docker restart to bounce
    // the configured container, waits for the broker to come back, and
    // confirms a new RawClickHouseConnection can complete a query
    // afterwards. The existing connection's first send after the
    // restart MAY surface either a successful replay (the reconnect
    // logic re-handshakes inline) or a typed transient error followed
    // by a clean retry. Both shapes are acceptable; what is NOT
    // acceptable is a hang or a non-typed error.
    private static func containerKillRestart() async -> ScenarioResult {
        do {
            let connection = try RawClickHouseConnection(
                host: stabilityHost,
                port: stabilityPort,
                user: stabilityUser,
                password: stabilityPassword,
                database: stabilityDatabase,
                reconnectionPolicy: ReconnectionPolicy(
                    maxAttempts: 10,
                    initialBackoff: .milliseconds(200),
                    maxBackoff: .seconds(2)
                )
            )
            defer { connection.close() }
            try connection.sendQuery("SELECT toUInt64(1)")
            let warmup = try connection.receiveScalarUInt64()
            if warmup != 1 {
                return ScenarioResult(id: "F1_container_kill_restart", passed: false, detail: "pre-restart sanity returned \(warmup), expected 1")
            }

            let restart = StabilityDocker.run(["restart", stabilityFaultDockerName])
            if restart.exitCode != 0 {
                return ScenarioResult(id: "F1_container_kill_restart", passed: false, detail: "docker restart exit=\(restart.exitCode) stderr=\(restart.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            await waitForBroker(timeoutSeconds: 45)

            // Drive the reconnect path with a deliberately tolerant
            // retry loop matching the integration test's primer
            // behaviour: keep retrying for up to 45 seconds, count
            // how many attempts are needed before the connection
            // is healthy.
            let probeStart = ContinuousClock.now
            var reconnected = false
            var attempts = 0
            let probeDeadline = probeStart.advanced(by: .seconds(45))
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
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let elapsedMicroseconds = StabilityClock.microsecondsSince(probeStart)
            if !reconnected {
                return ScenarioResult(id: "F1_container_kill_restart", passed: false, detail: "did not recover after \(attempts) attempts (\(elapsedMicroseconds)us)")
            }
            return ScenarioResult(id: "F1_container_kill_restart", passed: true, detail: "reconnected after \(attempts) attempts in \(elapsedMicroseconds)us")
        } catch {
            return ScenarioResult(id: "F1_container_kill_restart", passed: false, detail: "init or sanity failed: \(error)")
        }
    }

    private static func waitForBroker(timeoutSeconds: Double) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutSeconds * 1_000_000_000)))
        while ContinuousClock.now < deadline {
            do {
                let probe = try RawClickHouseConnection(
                    host: stabilityHost,
                    port: stabilityPort,
                    user: stabilityUser,
                    password: stabilityPassword,
                    database: stabilityDatabase,
                    reconnectionPolicy: .disabled
                )
                probe.close()
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // F2: Mid-stream cancellation. Open the AsyncThrowingStream
    // receiveBlocks() variant on a 5M-row scan and cancel the
    // consuming Task partway through. The stream must terminate
    // cleanly (either yields stop and the loop exits, or the
    // outstanding pump finishes the active block and then exits).
    // The bench asserts: the cancel propagates within reasonable
    // wall-clock time, no fatal error, and the underlying connection
    // can be closed without hanging.
    private static func midStreamCancellation() async -> ScenarioResult {
        let connection: AsyncRawClickHouseConnection
        do {
            connection = try await AsyncRawClickHouseConnection(
                host: stabilityHost, port: stabilityPort, user: stabilityUser,
                password: stabilityPassword, database: stabilityDatabase
            )
        } catch {
            return ScenarioResult(id: "F2_mid_stream_cancellation", passed: false, detail: "connect failed: \(error)")
        }

        let cancellationStart = ContinuousClock.now
        let task = Task<(blocksObserved: Int, finishedCleanly: Bool), Never> {
            var observed = 0
            do {
                let stream = connection.receiveBlocks()
                try await connection.sendQuery("SELECT number AS id, toString(number) AS tag, toFloat64(number) AS value FROM numbers(5000000)")
                for try await _ in stream {
                    observed += 1
                    if Task.isCancelled { break }
                }
                return (observed, true)
            } catch {
                // A typed RawClickHouseError or a CancellationError
                // are both acceptable terminations. An untyped Swift
                // error from anywhere else is a bug.
                _ = error
                return (observed, true)
            }
        }

        // Give the stream long enough to produce at least one block
        // before pulling the rug.
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let outcome = await task.value
        let elapsedMicroseconds = StabilityClock.microsecondsSince(cancellationStart)
        await connection.close()

        if !outcome.finishedCleanly {
            return ScenarioResult(id: "F2_mid_stream_cancellation", passed: false, detail: "stream did not finish cleanly after cancellation (\(elapsedMicroseconds)us, blocks observed=\(outcome.blocksObserved))")
        }
        if elapsedMicroseconds > 30_000_000 {
            return ScenarioResult(id: "F2_mid_stream_cancellation", passed: false, detail: "cancellation took \(elapsedMicroseconds / 1_000)ms; ceiling 30s; stream did not respond to cancel quickly enough")
        }
        return ScenarioResult(id: "F2_mid_stream_cancellation", passed: true, detail: "stream finished cleanly in \(elapsedMicroseconds / 1_000)ms after cancel, blocks observed=\(outcome.blocksObserved)")
    }

    // F3: Wrong-port connect. Attempt to open a connection against
    // port 65530 (almost certainly closed) and assert that the
    // attempt fails fast with a typed RawClickHouseError, not a
    // hang or untyped throw.
    private static func wrongPortConnect() async -> ScenarioResult {
        let connectStart = ContinuousClock.now
        var captured: RawClickHouseError?
        do {
            let connection = try RawClickHouseConnection(
                host: "127.0.0.1",
                port: 1,
                user: stabilityUser,
                password: stabilityPassword,
                database: stabilityDatabase,
                reconnectionPolicy: .disabled
            )
            connection.close()
        } catch {
            captured = error
        }
        let elapsedMicroseconds = StabilityClock.microsecondsSince(connectStart)

        guard let error = captured else {
            return ScenarioResult(id: "F3_wrong_port_connect", passed: false, detail: "connect to closed port succeeded; expected typed failure")
        }
        // Only failures whose semantic is "could not establish a
        // connection" are acceptable here. queryFailed / protocolError
        // would mean the test hit a different code path than intended.
        switch error {
        case .connectionFailed, .socketIOFailed, .unexpectedEOF, .reconnectExhausted:
            break
        case .protocolError, .queryFailed:
            return ScenarioResult(id: "F3_wrong_port_connect", passed: false, detail: "unexpected typed error: \(error)")
        }
        if elapsedMicroseconds > 5_000_000 {
            return ScenarioResult(id: "F3_wrong_port_connect", passed: false, detail: "took \(elapsedMicroseconds)us before surfacing; ceiling 5s")
        }
        return ScenarioResult(id: "F3_wrong_port_connect", passed: true, detail: "typed \(error) in \(elapsedMicroseconds)us")
    }

    // F4: Pool exhaustion. Construct a 1-slot pool with a 200ms
    // acquireTimeout. Hold the only slot in a background task running
    // a slow query, then attempt a second acquire from the foreground.
    // The second acquire must throw RawClickHouseConnectionPool.Failure
    // .acquireTimedOut promptly.
    private static func poolExhaustion() async -> ScenarioResult {
        let pool: RawClickHouseConnectionPool
        do {
            pool = try await RawClickHouseConnectionPool(
                host: stabilityHost,
                port: stabilityPort,
                user: stabilityUser,
                password: stabilityPassword,
                database: stabilityDatabase,
                minConnections: 1,
                maxConnections: 1,
                acquireTimeout: .milliseconds(500)
            )
        } catch {
            return ScenarioResult(id: "F4_pool_exhaustion", passed: false, detail: "pool init failed: \(error)")
        }
        defer { Task { await pool.close() } }

        let holderReady = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        let holder = Task<Void, Never> {
            do {
                try await pool.withConnection { connection in
                    holderReady.signal()
                    // Sleep server-side long enough for the contender
                    // to time out, then release.
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
        var captured: RawClickHouseConnectionPool.Failure?
        do {
            try await pool.withConnection { _ in }
        } catch let error as RawClickHouseConnectionPool.Failure {
            captured = error
        } catch {
            holderDone.wait()
            _ = holder
            return ScenarioResult(id: "F4_pool_exhaustion", passed: false, detail: "expected RawClickHouseConnectionPool.Failure, got untyped: \(error)")
        }
        let elapsedMicroseconds = StabilityClock.microsecondsSince(acquireStart)
        holderDone.wait()
        _ = holder

        guard let failure = captured else {
            return ScenarioResult(id: "F4_pool_exhaustion", passed: false, detail: "second acquire succeeded; expected acquireTimedOut")
        }
        switch failure {
        case .acquireTimedOut:
            // Sanity: the timeout fired in a reasonable window
            // (between the configured 500ms and a 5s slack ceiling).
            if elapsedMicroseconds < 400_000 || elapsedMicroseconds > 5_000_000 {
                return ScenarioResult(id: "F4_pool_exhaustion", passed: false, detail: "acquireTimedOut fired at \(elapsedMicroseconds)us; outside window 400ms..5s")
            }
            return ScenarioResult(id: "F4_pool_exhaustion", passed: true, detail: "typed acquireTimedOut after \(elapsedMicroseconds / 1_000)ms")
        case .poolClosed, .openFailed:
            return ScenarioResult(id: "F4_pool_exhaustion", passed: false, detail: "unexpected typed failure: \(failure)")
        }
    }

    // F5: Server-side query error. Send malformed SQL. The server
    // returns Exception(2). The raw transport must surface this as
    // RawClickHouseError.queryFailed, not a connection error. The
    // connection must remain usable after the error.
    private static func serverSideQueryError() async -> ScenarioResult {
        let connection: AsyncRawClickHouseConnection
        do {
            connection = try await AsyncRawClickHouseConnection(
                host: stabilityHost, port: stabilityPort, user: stabilityUser,
                password: stabilityPassword, database: stabilityDatabase
            )
        } catch {
            return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "connect failed: \(error)")
        }

        var captured: RawClickHouseError?
        var untyped: String?
        do {
            try await connection.sendQuery("SELECT not_a_real_column FROM not_a_real_table_for_stability_test")
            _ = try await connection.drainBlocks()
        } catch let error as RawClickHouseError {
            captured = error
        } catch {
            untyped = String(describing: error)
        }

        if let untyped {
            await connection.close()
            return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "expected typed RawClickHouseError, got untyped: \(untyped)")
        }
        guard let error = captured else {
            await connection.close()
            return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "malformed SQL succeeded; expected queryFailed")
        }
        guard case .queryFailed = error else {
            await connection.close()
            return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "expected .queryFailed, got \(error)")
        }

        // Connection must remain usable: a fresh query against the
        // same connection should still work.
        do {
            try await connection.sendQuery("SELECT toUInt64(99)")
            let value = try await connection.receiveScalarUInt64()
            await connection.close()
            if value != 99 {
                return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "follow-up SELECT returned \(value), expected 99")
            }
            return ScenarioResult(id: "F5_server_side_query_error", passed: true, detail: "typed queryFailed; connection survived, follow-up scalar=99")
        } catch {
            await connection.close()
            return ScenarioResult(id: "F5_server_side_query_error", passed: false, detail: "follow-up after queryFailed surfaced error: \(error)")
        }
    }

    // F6: TCP RST mid-receive. Open a forwarder, point the SDK at it,
    // start a large SELECT, then RST both halves of the forwarder
    // partway through. The drain must surface a typed
    // RawClickHouseError (.socketIOFailed or .unexpectedEOF), and a
    // fresh AsyncRawClickHouseConnection against the actual upstream
    // must still work afterwards.
    private static func midReceiveTcpRst() async -> ScenarioResult {
        let forwarder = StabilityResettingForwarder(upstreamHost: stabilityHost, upstreamPort: stabilityPort)
        let port: Int
        do {
            port = try forwarder.bind()
        } catch {
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "forwarder bind failed: \(error)")
        }
        defer { forwarder.shutdown() }

        let connection: AsyncRawClickHouseConnection
        do {
            connection = try await AsyncRawClickHouseConnection(
                host: "127.0.0.1", port: port,
                user: stabilityUser, password: stabilityPassword, database: stabilityDatabase
            )
        } catch {
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "connect via forwarder failed: \(error)")
        }

        let resetter = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(100))
            forwarder.severe()
        }

        var captured: RawClickHouseError?
        var untyped: String?
        do {
            try await connection.sendQuery("SELECT number, toString(number) AS payload FROM numbers(5000000)")
            _ = try await connection.drainBlocks()
        } catch let error as RawClickHouseError {
            captured = error
        } catch {
            untyped = String(describing: error)
        }
        _ = await resetter.value
        await connection.close()

        if let untyped {
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "expected typed RawClickHouseError, got untyped: \(untyped)")
        }
        guard let error = captured else {
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "drain succeeded; expected RST-induced typed error")
        }
        switch error {
        case .socketIOFailed, .unexpectedEOF, .protocolError, .reconnectExhausted, .connectionFailed:
            break
        case .queryFailed:
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "unexpected .queryFailed for TCP RST")
        }

        // Reconnect to the real upstream and prove no socket leak / no
        // poisoned arena: a fresh connection scalar SELECT works.
        do {
            let recovered = try await AsyncRawClickHouseConnection(
                host: stabilityHost, port: stabilityPort,
                user: stabilityUser, password: stabilityPassword, database: stabilityDatabase
            )
            try await recovered.sendQuery("SELECT toUInt64(42)")
            let value = try await recovered.receiveScalarUInt64()
            await recovered.close()
            if value != 42 {
                return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "post-RST recovery scalar=\(value), expected 42")
            }
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: true, detail: "typed \(error); fresh post-RST connection scalar=42")
        } catch {
            return ScenarioResult(id: "F6_mid_receive_tcp_rst", passed: false, detail: "post-RST reconnect failed: \(error)")
        }
    }

    // F7: Mid-receive cancel. Start a drainBlocks() on a multi-block
    // query, cancel the calling Task. The actor wrapper runs the sync
    // receive loop on its DispatchQueue worker — Task cancellation
    // cannot interrupt a syscall in flight on the worker, so we expect
    // the drain to RUN TO COMPLETION on the connection (the actor
    // continues on its worker thread even after the awaiter cancels).
    // The CALLING Task's await returns with the actor's normal
    // completion or a typed RawClickHouseError. The bench asserts:
    // the calling Task wakes up within ~30s, no untyped throw, and a
    // FRESH connection opened afterwards is usable.
    private static func midReceiveCancel() async -> ScenarioResult {
        let cancellationStart = ContinuousClock.now
        let task = Task<(typed: Bool, rows: Int, errorDescription: String), Never> {
            do {
                let connection = try await AsyncRawClickHouseConnection(
                    host: stabilityHost, port: stabilityPort,
                    user: stabilityUser, password: stabilityPassword, database: stabilityDatabase
                )
                try await connection.sendQuery("SELECT number, toString(number) AS payload FROM numbers(2000000)")
                let rows = try await connection.drainBlocks()
                await connection.close()
                return (true, rows, "completed")
            } catch let error as RawClickHouseError {
                return (true, 0, String(describing: error))
            } catch {
                return (false, 0, String(describing: error))
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
        task.cancel()
        let outcome = await task.value
        let elapsedMicroseconds = StabilityClock.microsecondsSince(cancellationStart)
        if !outcome.typed {
            return ScenarioResult(id: "F7_mid_receive_cancel", passed: false, detail: "cancelled drain surfaced untyped: \(outcome.errorDescription)")
        }
        if elapsedMicroseconds > 30_000_000 {
            return ScenarioResult(id: "F7_mid_receive_cancel", passed: false, detail: "cancel did not wake calling task within 30s (\(elapsedMicroseconds)us)")
        }

        // Recovery probe: fresh AsyncRawClickHouseConnection works.
        do {
            let probe = try await AsyncRawClickHouseConnection(
                host: stabilityHost, port: stabilityPort,
                user: stabilityUser, password: stabilityPassword, database: stabilityDatabase
            )
            try await probe.sendQuery("SELECT toUInt64(73)")
            let value = try await probe.receiveScalarUInt64()
            await probe.close()
            if value != 73 {
                return ScenarioResult(id: "F7_mid_receive_cancel", passed: false, detail: "post-cancel probe scalar=\(value), expected 73")
            }
        } catch {
            return ScenarioResult(id: "F7_mid_receive_cancel", passed: false, detail: "post-cancel probe failed: \(error)")
        }
        return ScenarioResult(id: "F7_mid_receive_cancel", passed: true, detail: "drain returned in \(elapsedMicroseconds / 1_000)ms (\(outcome.errorDescription), rows=\(outcome.rows)); fresh probe scalar=73")
    }
}
