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

import Logging
import Metrics
import MetricsTestKit
import Synchronization
import Testing

@testable import DXRedis

final class CapturedRedisLogs: Sendable {

    private let messages = Mutex<[String]>([])

    func append(_ message: String) {
        messages.withLock { $0.append(message) }
    }

    func all() -> [String] {
        messages.withLock { $0 }
    }
}

struct CapturingRedisLogHandler: LogHandler {

    let captured: CapturedRedisLogs
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

@Suite struct RedisObservabilityTests {

    @Test func recorderAccumulatesAndSnapshots() {
        let recorder = RedisMetricsRecorder()
        recorder.recordCommand(durationNanos: 1_000_000)
        recorder.recordCommand(durationNanos: 3_000_000)
        recorder.recordError()
        recorder.recordRetry()
        recorder.recordPoolTimeout()
        recorder.recordConnectionOpened()

        let snapshot = recorder.snapshot()
        #expect(snapshot.commandsTotal == 2)
        #expect(snapshot.commandErrorsTotal == 1)
        #expect(snapshot.retriesTotal == 1)
        #expect(snapshot.poolTimeoutsTotal == 1)
        #expect(snapshot.connectionsOpenedTotal == 1)
        #expect(snapshot.totalCommandDurationNanos == 4_000_000)
        #expect(snapshot.meanCommandDurationNanos == 2_000_000)
    }

    @Test func labelDecodesVerbLazily() {
        #expect(RedisOperationLabel.verb(Array("get".utf8)).name == "GET")
        #expect(RedisOperationLabel.verb(Array("HSET".utf8)).name == "HSET")
        #expect(RedisOperationLabel.fixed("PIPELINE").name == "PIPELINE")
    }

    private func makeClient(_ captured: CapturedRedisLogs) -> RedisClient {
        var logger = Logger(label: "test", factory: { _ in CapturingRedisLogHandler(captured: captured) })
        logger.logLevel = .trace
        return RedisClient(configuration: RedisConfiguration(
            endpoint: RedisEndpoint(host: "localhost"),
            resilience: .disabled,
            logger: logger
        ))
    }

    @Test func emitsStartedAndCompletedOnSuccess() async throws {
        let captured = CapturedRedisLogs()
        let client = makeClient(captured)
        let value = try await client.withResilience(.verb(Array("get".utf8))) { 7 }
        #expect(value == 7)
        let messages = captured.all()
        #expect(messages.contains("command.started"))
        #expect(messages.contains("command.completed"))
        await client.shutdown()
    }

    @Test func emitsFailedOnError() async {
        let captured = CapturedRedisLogs()
        let client = makeClient(captured)
        await #expect(throws: RedisError.self) {
            try await client.withResilience(.fixed("PIPELINE")) { () throws -> Int in
                throw RedisError.connectionClosed
            }
        }
        #expect(captured.all().contains("command.failed"))
        #expect(client.metrics().commandErrorsTotal == 1)
        await client.shutdown()
    }

    @Test func emitsSwiftMetricsInstruments() throws {
        let backend = TestMetrics()
        withMetricsFactory(backend) {
            let recorder = RedisMetricsRecorder()
            recorder.recordCommand(durationNanos: 2_000_000)
            recorder.recordError()
            recorder.recordRetry()
            recorder.recordPoolTimeout()
            recorder.recordConnectionOpened()
            recorder.recordPoolGauges(idle: 2, inUse: 1)
        }

        #expect(try backend.expectCounter("redis.commands").totalValue == 1)
        #expect(try backend.expectCounter("redis.command.errors").totalValue == 1)
        #expect(try backend.expectCounter("redis.command.retries").totalValue == 1)
        #expect(try backend.expectCounter("redis.pool.timeouts").totalValue == 1)
        #expect(try backend.expectCounter("redis.connections.opened").totalValue == 1)
        #expect(try backend.expectTimer("redis.command.duration").values.count == 1)
        #expect(try backend.expectGauge("redis.pool.idle").values.count == 1)
        #expect(try backend.expectGauge("redis.pool.in_use").values.count == 1)
    }
}
