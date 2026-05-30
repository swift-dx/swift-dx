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
import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Fault-injection coverage for the reconnect path. Gated by
// CH_FAULT_DOCKER_NAME so it only runs when the test environment
// permits a `sudo docker restart` of the local ClickHouse container.
// CI configures the variable; developer machines opt in by setting it
// when running this suite.
@Suite(
    "ClickHouseConnection reconnection fault tests",
    .enabled(if: ProcessInfo.processInfo.environment["CH_FAULT_DOCKER_NAME"] != nil
            && ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil)
)
struct ClickHouseReconnectionFaultTests {

    private static var host: String {
        ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] ?? "localhost"
    }

    private static var port: Int {
        Int(ProcessInfo.processInfo.environment["CH_INTEGRATION_PORT"] ?? "9000") ?? 9000
    }

    private static var containerName: String {
        ProcessInfo.processInfo.environment["CH_FAULT_DOCKER_NAME"] ?? "swift-dx-clickhouse1"
    }

    // Drop the established TCP connection by restarting the server
    // container. The client's next syscall on the socket sees
    // ECONNRESET / EOF, the reconnect path opens a fresh socket and
    // re-handshakes, and the surfaced error has the typed shape the
    // caller can match on.
    @Test("Send after a server restart reconnects and resurfaces the typed I/O error")
    func sendAfterServerRestartReconnects() throws {
        let connection = try ClickHouseConnection(
            host: Self.host,
            port: Self.port,
            reconnectionPolicy: ReconnectionPolicy(
                maxAttempts: 10,
                initialBackoff: .milliseconds(200),
                maxBackoff: .seconds(2)
            )
        )
        defer { connection.close() }
        try connection.sendQuery("SELECT 1")
        _ = try connection.receiveBlocksDrain { _, _, _ in }

        // Restart the broker and wait for it to come back online.
        restartContainer(name: Self.containerName)
        waitForBroker(host: Self.host, port: Self.port, timeoutSeconds: 30)

        // The very first send is what triggers reconnection. The
        // typed-throws contract says either the send succeeds (the
        // server is back, our reconnect inside sendQuery succeeded
        // and replayed) or the send surfaces a typed error.
        do {
            try connection.sendQuery("SELECT toUInt64(7)")
            let value = try connection.receiveScalarUInt64()
            #expect(value == 7)
        } catch let error {
            switch error {
            case .socketIOFailed, .unexpectedEOF, .connectionFailed, .reconnectExhausted, .endpointsExhausted, .queryTimeout:
                // Acceptable transient outcomes: the test does NOT
                // require the very-first replay to succeed in every
                // race; what it requires is that the FOLLOWUP send,
                // after the broker is healthy and the connection has
                // had a fresh chance to reconnect, succeeds with the
                // expected scalar.
                break
            case .protocolError, .queryFailed:
                Issue.record("unexpected typed error after restart: \(error)")
            }
            waitForBroker(host: Self.host, port: Self.port, timeoutSeconds: 30)
            try connection.sendQuery("SELECT toUInt64(13)")
            let value = try connection.receiveScalarUInt64()
            #expect(value == 13)
        }
    }

    // After the reconnect succeeds, the connection should be fully
    // usable for many more queries without reopening externally.
    @Test("Connection is usable for many queries after a reconnect")
    func manyQueriesAfterReconnect() throws {
        let connection = try ClickHouseConnection(
            host: Self.host,
            port: Self.port,
            reconnectionPolicy: ReconnectionPolicy(
                maxAttempts: 10,
                initialBackoff: .milliseconds(200),
                maxBackoff: .seconds(2)
            )
        )
        defer { connection.close() }
        try connection.sendQuery("SELECT 1")
        _ = try connection.receiveBlocksDrain { _, _, _ in }

        restartContainer(name: Self.containerName)
        waitForBroker(host: Self.host, port: Self.port, timeoutSeconds: 30)

        // Drive the reconnect path with a deliberately tolerant first
        // round-trip: keep retrying until we get a clean answer, then
        // run a dense series of follow-ups.
        let primer = primeConnection(connection: connection, deadlineSeconds: 30)
        #expect(primer == true)

        for index in 1...10 {
            try connection.sendQuery("SELECT toUInt64(\(index))")
            let value = try connection.receiveScalarUInt64()
            #expect(value == UInt64(index))
        }
    }

    private func primeConnection(connection: ClickHouseConnection, deadlineSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            do {
                try connection.sendQuery("SELECT toUInt64(1)")
                let value = try connection.receiveScalarUInt64()
                if value == 1 { return true }
            } catch {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        return false
    }

    private func restartContainer(name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "docker", "restart", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Issue.record("failed to spawn docker restart: \(error)")
        }
    }

    private func waitForBroker(host: String, port: Int, timeoutSeconds: Double) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            do {
                let probe = try ClickHouseConnection(host: host, port: port, reconnectionPolicy: .disabled)
                probe.close()
                return
            } catch {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}
