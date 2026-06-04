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

import Atomics
import Logging
import Metrics
import MetricsTestKit
import Synchronization
import Testing

@testable import DXPostgresPrevious

final class CapturedLogs: Sendable {

    private let messages = Mutex<[String]>([])

    func append(_ message: String) {
        messages.withLock { $0.append(message) }
    }

    func all() -> [String] {
        messages.withLock { $0 }
    }
}

struct CapturingLogHandler: LogHandler {

    let captured: CapturedLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        captured.append(event.message.description)
    }
}

@Suite struct ObservabilityTests {

    @Test func recorderAccumulatesAndSnapshots() {
        let recorder = PostgresMetricsRecorder()
        recorder.recordQuery(durationNanos: 1_000_000)
        recorder.recordQuery(durationNanos: 3_000_000)
        recorder.recordError()
        recorder.recordRetry()
        recorder.recordRetry()
        recorder.recordPoolTimeout()
        recorder.recordConnectionOpened()

        let snapshot = recorder.snapshot()
        #expect(snapshot.queriesTotal == 2)
        #expect(snapshot.queryErrorsTotal == 1)
        #expect(snapshot.retriesTotal == 2)
        #expect(snapshot.poolTimeoutsTotal == 1)
        #expect(snapshot.connectionsOpenedTotal == 1)
        #expect(snapshot.totalQueryDurationNanos == 4_000_000)
        #expect(snapshot.meanQueryDurationNanos == 2_000_000)
    }

    @Test func meanIsZeroWithoutQueries() {
        #expect(PostgresMetricsRecorder().snapshot().meanQueryDurationNanos == 0)
    }

    @Test func descriptorExtractsLeadingKeyword() {
        #expect(PostgresStatementDescriptor.operation(of: "SELECT 1") == "SELECT")
        #expect(PostgresStatementDescriptor.operation(of: "  insert into accounts") == "INSERT")
        #expect(PostgresStatementDescriptor.operation(of: "update\n  accounts set") == "UPDATE")
        #expect(PostgresStatementDescriptor.operation(of: "\t  delete from x") == "DELETE")
        #expect(PostgresStatementDescriptor.operation(of: "") == "QUERY")
        #expect(PostgresStatementDescriptor.operation(of: "   ") == "QUERY")
    }

    private func makeClient(_ captured: CapturedLogs) -> PostgresClient {
        var logger = Logger(label: "test", factory: { _ in CapturingLogHandler(captured: captured) })
        logger.logLevel = .trace
        return PostgresClient(configuration: PostgresConfiguration(
            endpoint: PostgresEndpoint(host: "localhost"),
            credentials: .password(username: "u", password: "p"),
            database: PostgresDatabaseName("db"),
            resilience: .disabled,
            logger: logger
        ))
    }

    @Test func emitsStartedAndCompletedOnSuccess() async throws {
        let captured = CapturedLogs()
        let client = makeClient(captured)
        let value = try await client.withResilience(statement: "SELECT 42") { 42 }
        #expect(value == 42)
        let messages = captured.all()
        #expect(messages.contains("query.started"))
        #expect(messages.contains("query.completed"))
        await client.shutdown()
    }

    @Test func emitsFailedOnError() async {
        let captured = CapturedLogs()
        let client = makeClient(captured)
        await #expect(throws: PostgresError.self) {
            try await client.withResilience(statement: "SELECT 1") { () throws -> Int in
                throw PostgresError.connectionClosed
            }
        }
        #expect(captured.all().contains("query.failed"))
        await client.shutdown()
    }

    // Binds a TestMetrics backend to a task-local factory so the recorder's
    // instruments bind to it (no global bootstrap, fully isolated from other
    // tests in the shared binary), then proves every recorder event reaches an
    // instrument with exact counts.
    @Test func emitsSwiftMetricsInstruments() throws {
        let backend = TestMetrics()
        withMetricsFactory(backend) {
            let recorder = PostgresMetricsRecorder()
            recorder.recordQuery(durationNanos: 2_000_000)
            recorder.recordError()
            recorder.recordRetry()
            recorder.recordPoolTimeout()
            recorder.recordConnectionOpened()
            recorder.recordPoolGauges(idle: 3, inUse: 1)
        }

        #expect(try backend.expectCounter("postgres.queries").totalValue == 1)
        #expect(try backend.expectCounter("postgres.query.errors").totalValue == 1)
        #expect(try backend.expectCounter("postgres.query.retries").totalValue == 1)
        #expect(try backend.expectCounter("postgres.pool.timeouts").totalValue == 1)
        #expect(try backend.expectCounter("postgres.connections.opened").totalValue == 1)
        #expect(try backend.expectTimer("postgres.query.duration").values.count == 1)
        #expect(try backend.expectGauge("postgres.pool.idle").values.count == 1)
        #expect(try backend.expectGauge("postgres.pool.in_use").values.count == 1)
    }
}
