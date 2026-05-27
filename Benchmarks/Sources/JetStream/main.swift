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

import DXCore
import DXJetStream
import Foundation
import NIOCore
import NIOPosix

func envInt(_ key: String, _ fallback: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty, let value = Int(raw) else {
        return fallback
    }
    return value
}

func envString(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

func envBool(_ key: String, _ fallback: Bool) -> Bool {
    envInt(key, fallback ? 1 : 0) != 0
}

func filler(_ targetBytes: Int) -> String {
    let n = max(0, targetBytes - 16)
    return String(repeating: "x", count: n)
}

func payloadBytes(filler: String, index: Int) -> [UInt8] {
    Array("\(index)-\(filler)".utf8)
}

func percentile(sorted: [Int64], p: Double) -> Int64 {
    if sorted.isEmpty { return 0 }
    var idx = Int(Double(sorted.count - 1) * p)
    idx = max(0, min(idx, sorted.count - 1))
    return sorted[idx]
}

func microString(_ micros: Int64) -> String { "\(micros)us" }

func latencySummaryMicros(samples: [Int64]) -> String {
    let sorted = samples.sorted()
    let largest = sorted.last ?? 0
    return "p50=\(microString(percentile(sorted: sorted, p: 0.50))) p95=\(microString(percentile(sorted: sorted, p: 0.95))) p99=\(microString(percentile(sorted: sorted, p: 0.99))) p999=\(microString(percentile(sorted: sorted, p: 0.999))) max=\(microString(largest))"
}

func rate(count: Int, elapsedSeconds: Double) -> Int {
    elapsedSeconds <= 0 ? 0 : Int(Double(count) / elapsedSeconds)
}

func elapsedMicros(_ since: ContinuousClock.Instant) -> Int64 {
    let dur = since.duration(to: .now)
    return dur.components.seconds * 1_000_000 + dur.components.attoseconds / 1_000_000_000_000
}

func elapsedMicros(_ from: ContinuousClock.Instant, to: ContinuousClock.Instant) -> Int64 {
    let dur = from.duration(to: to)
    return dur.components.seconds * 1_000_000 + dur.components.attoseconds / 1_000_000_000_000
}

func elapsedSeconds(_ since: ContinuousClock.Instant) -> Double {
    let dur = since.duration(to: .now)
    return Double(dur.components.seconds) + Double(dur.components.attoseconds) / 1e18
}

func randomSuffix() -> String {
    String(format: "%08x", UInt32.random(in: .min ... .max))
}

let host = envString("NATS_HOST", "127.0.0.1")
let port = envInt("NATS_PORT", 4222)
let modeRaw = envString("NATS_PERF_MODE", "publish,fetch")
let totalPublish = envInt("NATS_PERF_PUBLISH_MESSAGES", 100_000)
let publishBatch = envInt("NATS_PERF_PUBLISH_BATCHES", 1_000)
let connsCount = envInt("NATS_PERF_CONNECTIONS", 1)
let payloadSize = envInt("NATS_PERF_PAYLOAD_BYTES", 64)
let useMsgId = envBool("NATS_PERF_USE_MSGID", true)
let drainPerBatch = envBool("NATS_PERF_DRAIN_PER_BATCH", true)
let pipelineDepth = envInt("NATS_PERF_PUBLISH_PIPELINE", 8)
let maxAckPending = envInt("NATS_PERF_MAX_ACK_PENDING", 1_000)
let totalFetch = envInt("NATS_PERF_FETCH_MESSAGES", 100_000)
let fetchBatch = envInt("NATS_PERF_FETCH_BATCHES", 1_000)
let fetchRoundtrips = envInt("NATS_PERF_FETCH_ROUNDTRIPS", 2_000)
let seedBatch = envInt("NATS_PERF_FETCH_SEED_BATCH", 1_000)
let seedPipelines = envInt("NATS_PERF_FETCH_SEED_PIPELINES", 8)

let modes = modeRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
let runSuffix = randomSuffix()
let fillString = filler(payloadSize)

let elGroupThreads = envInt("NATS_PERF_EL_THREADS", 0)
let configuration: JetStreamConfiguration = {
    let endpoint = NatsEndpoint(host: host, port: port)
    if elGroupThreads > 0 {
        let elGroup: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: elGroupThreads)
        return JetStreamConfiguration(endpoint: endpoint, eventLoopGroup: elGroup)
    }
    if elGroupThreads < 0 {
        return JetStreamConfiguration(endpoint: endpoint, eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
    }
    return JetStreamConfiguration(endpoint: endpoint, expectedConnections: connsCount)
}()

func publishShard(client: any JetStreamClient, subject: Subject, lo: Int, hi: Int, connIdx: Int) async throws -> (latencies: [Int64], buildMicros: [Int64], enqueueMicros: [Int64], waitMicros: [Int64]) {
    var latencies: [Int64] = []
    var buildMicros: [Int64] = []
    var enqueueMicros: [Int64] = []
    var waitMicros: [Int64] = []
    let shardCount = hi - lo
    latencies.reserveCapacity((shardCount + publishBatch - 1) / publishBatch)

    if drainPerBatch {
        var index = lo
        while index < hi {
            let upper = min(index + publishBatch, hi)
            let callStart = ContinuousClock.now
            if useMsgId {
                let messages = (index..<upper).map { i in
                    NatsOutgoingMessage(
                        dedup: .dedupId("mc-\(runSuffix)-c\(connIdx)-b\(publishBatch)-\(i)"),
                        payload: payloadBytes(filler: fillString, index: i)
                    )
                }
                let afterBuild = ContinuousClock.now
                let handle = client.enqueue(to: subject, messages: messages)
                let afterEnqueue = ContinuousClock.now
                try await handle.wait()
                let afterWait = ContinuousClock.now
                buildMicros.append(elapsedMicros(callStart, to: afterBuild))
                enqueueMicros.append(elapsedMicros(afterBuild, to: afterEnqueue))
                waitMicros.append(elapsedMicros(afterEnqueue, to: afterWait))
            } else {
                let payloads = (index..<upper).map { i in payloadBytes(filler: fillString, index: i) }
                let afterBuild = ContinuousClock.now
                let handle = client.enqueue(to: subject, payloads: payloads)
                let afterEnqueue = ContinuousClock.now
                try await handle.wait()
                let afterWait = ContinuousClock.now
                buildMicros.append(elapsedMicros(callStart, to: afterBuild))
                enqueueMicros.append(elapsedMicros(afterBuild, to: afterEnqueue))
                waitMicros.append(elapsedMicros(afterEnqueue, to: afterWait))
            }
            latencies.append(elapsedMicros(callStart))
            index = upper
        }
    } else {
        var inflight: [PublishHandle] = []
        inflight.reserveCapacity(pipelineDepth)
        var index = lo
        while index < hi {
            if inflight.count >= pipelineDepth {
                let oldest = inflight.removeFirst()
                try await oldest.wait()
            }
            let upper = min(index + publishBatch, hi)
            let callStart = ContinuousClock.now
            let handle: PublishHandle
            if useMsgId {
                let messages = (index..<upper).map { i in
                    NatsOutgoingMessage(
                        dedup: .dedupId("mc-\(runSuffix)-c\(connIdx)-b\(publishBatch)-\(i)"),
                        payload: payloadBytes(filler: fillString, index: i)
                    )
                }
                handle = client.enqueue(to: subject, messages: messages)
            } else {
                let payloads = (index..<upper).map { i in payloadBytes(filler: fillString, index: i) }
                handle = client.enqueue(to: subject, payloads: payloads)
            }
            latencies.append(elapsedMicros(callStart))
            inflight.append(handle)
            index = upper
        }
        for handle in inflight {
            try await handle.wait()
        }
    }

    return (latencies, buildMicros, enqueueMicros, waitMicros)
}

func runPublishMode() async throws {
    let stream = try StreamName("SWIFTPERFPUB_\(runSuffix.uppercased())_B\(publishBatch)")
    let subject = try Subject("swiftperf.pub.\(runSuffix).b\(publishBatch)")

    let setupClient = try await JetStream.connect(configuration)
    try? await setupClient.delete(stream)
    try await setupClient.ensure(stream, subject: subject, storage: .file)
    await setupClient.close()

    let actualConns = max(1, connsCount)
    var clients: [any JetStreamClient] = []
    for _ in 0..<actualConns {
        clients.append(try await JetStream.connect(configuration))
    }

    let shardSize = (totalPublish + actualConns - 1) / actualConns
    let startInstant = ContinuousClock.now

    var allLatencies: [Int64] = []
    var allBuild: [Int64] = []
    var allEnqueue: [Int64] = []
    var allWait: [Int64] = []

    try await withThrowingTaskGroup(of: (latencies: [Int64], buildMicros: [Int64], enqueueMicros: [Int64], waitMicros: [Int64]).self) { group in
        for c in 0..<actualConns {
            let client = clients[c]
            let lo = c * shardSize
            let hi = min(lo + shardSize, totalPublish)
            if lo >= hi { continue }
            group.addTask {
                try await publishShard(client: client, subject: subject, lo: lo, hi: hi, connIdx: c)
            }
        }
        for try await result in group {
            allLatencies.append(contentsOf: result.latencies)
            allBuild.append(contentsOf: result.buildMicros)
            allEnqueue.append(contentsOf: result.enqueueMicros)
            allWait.append(contentsOf: result.waitMicros)
        }
    }

    let elapsed = elapsedSeconds(startInstant)

    for client in clients {
        await client.close()
    }

    let teardown = try await JetStream.connect(configuration)
    try? await teardown.delete(stream)
    await teardown.close()

    print(
        "[JS PERF SWIFT] bulk_publish conns=\(actualConns) batch=\(publishBatch) msgs=\(totalPublish) "
        + "elapsed=\(String(format: "%.2f", elapsed))s rate=\(rate(count: totalPublish, elapsedSeconds: elapsed))/s "
        + "drain_per_batch=\(drainPerBatch ? 1 : 0) pipeline=\(pipelineDepth) use_msgid=\(useMsgId ? 1 : 0) "
        + "\(latencySummaryMicros(samples: allLatencies))"
    )
    if !allBuild.isEmpty {
        print("[JS PERF SWIFT] phase_build_msgs (bench-side) \(latencySummaryMicros(samples: allBuild))")
        print("[JS PERF SWIFT] phase_enqueue    (library-side) \(latencySummaryMicros(samples: allEnqueue))")
        print("[JS PERF SWIFT] phase_wait       (server+ack)   \(latencySummaryMicros(samples: allWait))")
    }
}

func runPublishMode_OLD_SINGLE_CONN() async throws {
    try await JetStream.withClient(configuration) { client in
        let stream = try StreamName("SWIFTPERFPUB_\(runSuffix.uppercased())_B\(publishBatch)")
        let subject = try Subject("swiftperf.pub.\(runSuffix).b\(publishBatch)")
        try? await client.delete(stream)
        try await client.ensure(stream, subject: subject, storage: .file)

        var latencies: [Int64] = []
        latencies.reserveCapacity((totalPublish + publishBatch - 1) / publishBatch)

        let startInstant = ContinuousClock.now

        var buildMicros: [Int64] = []
        var enqueueMicros: [Int64] = []
        var waitMicros: [Int64] = []

        if drainPerBatch {
            var index = 0
            while index < totalPublish {
                let upper = min(index + publishBatch, totalPublish)
                let callStart = ContinuousClock.now
                if useMsgId {
                    let messages = (index..<upper).map { i in
                        NatsOutgoingMessage(
                            dedup: .dedupId("mc-\(runSuffix)-b\(publishBatch)-\(i)"),
                            payload: payloadBytes(filler: fillString, index: i)
                        )
                    }
                    let afterBuild = ContinuousClock.now
                    let handle = client.enqueue(to: subject, messages: messages)
                    let afterEnqueue = ContinuousClock.now
                    try await handle.wait()
                    let afterWait = ContinuousClock.now
                    buildMicros.append(elapsedMicros(callStart, to: afterBuild))
                    enqueueMicros.append(elapsedMicros(afterBuild, to: afterEnqueue))
                    waitMicros.append(elapsedMicros(afterEnqueue, to: afterWait))
                } else {
                    let payloads = (index..<upper).map { i in payloadBytes(filler: fillString, index: i) }
                    let afterBuild = ContinuousClock.now
                    let handle = client.enqueue(to: subject, payloads: payloads)
                    let afterEnqueue = ContinuousClock.now
                    try await handle.wait()
                    let afterWait = ContinuousClock.now
                    buildMicros.append(elapsedMicros(callStart, to: afterBuild))
                    enqueueMicros.append(elapsedMicros(afterBuild, to: afterEnqueue))
                    waitMicros.append(elapsedMicros(afterEnqueue, to: afterWait))
                }
                latencies.append(elapsedMicros(callStart))
                index = upper
            }
        } else {
            var inflight: [PublishHandle] = []
            inflight.reserveCapacity(pipelineDepth)
            var index = 0
            while index < totalPublish {
                if inflight.count >= pipelineDepth {
                    let oldest = inflight.removeFirst()
                    try await oldest.wait()
                }
                let upper = min(index + publishBatch, totalPublish)
                let callStart = ContinuousClock.now
                let handle: PublishHandle
                if useMsgId {
                    let messages = (index..<upper).map { i in
                        NatsOutgoingMessage(
                            dedup: .dedupId("mc-\(runSuffix)-b\(publishBatch)-\(i)"),
                            payload: payloadBytes(filler: fillString, index: i)
                        )
                    }
                    handle = client.enqueue(to: subject, messages: messages)
                } else {
                    let payloads = (index..<upper).map { i in payloadBytes(filler: fillString, index: i) }
                    handle = client.enqueue(to: subject, payloads: payloads)
                }
                latencies.append(elapsedMicros(callStart))
                inflight.append(handle)
                index = upper
            }
            for handle in inflight {
                try await handle.wait()
            }
        }

        let elapsed = elapsedSeconds(startInstant)
        print(
            "[JS PERF SWIFT] bulk_publish conns=\(connsCount) batch=\(publishBatch) msgs=\(totalPublish) "
            + "elapsed=\(String(format: "%.2f", elapsed))s rate=\(rate(count: totalPublish, elapsedSeconds: elapsed))/s "
            + "drain_per_batch=\(drainPerBatch ? 1 : 0) pipeline=\(pipelineDepth) use_msgid=\(useMsgId ? 1 : 0) "
            + "\(latencySummaryMicros(samples: latencies))"
        )
        if !enqueueMicros.isEmpty {
            print("[JS PERF SWIFT] phase_build_msgs (bench-side) \(latencySummaryMicros(samples: buildMicros))")
            print("[JS PERF SWIFT] phase_enqueue    (library-side) \(latencySummaryMicros(samples: enqueueMicros))")
            print("[JS PERF SWIFT] phase_wait       (server+ack)   \(latencySummaryMicros(samples: waitMicros))")
        }
        try? await client.delete(stream)
    }
}

func seedStream<Client: JetStreamClient>(client: Client, subject: Subject, total: Int, batchSize: Int, pipelines: Int) async throws {
    var inflight: [PublishHandle] = []
    inflight.reserveCapacity(pipelines)
    var index = 0
    while index < total {
        if inflight.count >= pipelines {
            let oldest = inflight.removeFirst()
            try await oldest.wait()
        }
        let upper = min(index + batchSize, total)
        let payloads = (index..<upper).map { i in payloadBytes(filler: fillString, index: i) }
        inflight.append(client.enqueue(to: subject, payloads: payloads))
        index = upper
    }
    for handle in inflight {
        try await handle.wait()
    }
}

func runFetchMode() async throws {
    try await JetStream.withClient(configuration) { client in
        let stream = try StreamName("SWIFTPERFFETCH_\(runSuffix.uppercased())")
        let subject = try Subject("swiftperf.fetch.\(runSuffix)")
        let consumer = try ConsumerName("swiftperffetch_\(runSuffix)_b\(fetchBatch)")
        try? await client.delete(stream)
        try await client.ensure(stream, subject: subject, storage: .file)

        let seedStart = ContinuousClock.now
        try await seedStream(client: client, subject: subject, total: totalFetch, batchSize: seedBatch, pipelines: seedPipelines)
        print("[JS PERF SWIFT] fetch_seed msgs=\(totalFetch) elapsed=\(String(format: "%.2f", elapsedSeconds(seedStart)))s")

        var consumerConfiguration = ConsumerConfiguration.standard()
        consumerConfiguration.maxAckPending = maxAckPending
        try await client.ensure(consumer, on: stream, configuration: consumerConfiguration)
        let fs = try await client.fetch(from: stream, for: consumer, needsPayload: true)
        let limit = min(fetchBatch * fetchRoundtrips, totalFetch)

        var latencies: [Int64] = []
        var consumed = 0
        let start = ContinuousClock.now
        while consumed < limit {
            let remaining = limit - consumed
            let request = min(fetchBatch, remaining)
            let callStart = ContinuousClock.now
            let result = try await fs.requestAndAwait(batch: request, expires: .seconds(10), wait: .fill)
            latencies.append(elapsedMicros(callStart))
            if result.payloads.isEmpty { break }
            client.acknowledge(replies: result.replies)
            consumed += result.payloads.count
        }
        let elapsed = elapsedSeconds(start)
        await client.close(fs)
        print(
            "[JS PERF SWIFT] pull_fetch batch=\(fetchBatch) consumed=\(consumed) "
            + "elapsed=\(String(format: "%.2f", elapsed))s rate=\(rate(count: consumed, elapsedSeconds: elapsed))/s "
            + "round_trips=\(latencies.count) max_ack_pending=\(maxAckPending) "
            + "\(latencySummaryMicros(samples: latencies))"
        )
        try? await client.delete(stream)
    }
}

for selected in modes {
    switch selected {
    case "publish":
        try await runPublishMode()
    case "fetch":
        try await runFetchMode()
    default:
        print("unknown mode: \(selected)")
    }
}
