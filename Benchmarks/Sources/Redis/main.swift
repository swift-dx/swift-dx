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

import DXRedis
import Foundation
import NIOPosix

// Microbenchmark harness for DXRedis. Runs one or more named modes against a
// live Redis instance and prints a single-line summary per mode in the
// `[REDIS PERF SWIFT]` namespace, mirroring the ClickHouse benchmark output so
// a parser can pick both up uniformly. Modes are selected via REDIS_BENCH_MODES
// as a comma-separated list. Keys and values are generated before the timed
// section so the measurement isolates the client and the network from key
// formatting, matching the C comparison harness.

private func env(_ key: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ""
}

private func envInt(_ key: String, _ fallback: Int) -> Int {
    Int(env(key)) ?? fallback
}

private func envString(_ key: String, _ fallback: String) -> String {
    let value = env(key)
    return value.isEmpty ? fallback : value
}

private let host = envString("REDIS_BENCH_HOST", "127.0.0.1")
private let port = envInt("REDIS_BENCH_PORT", 6379)
private let password = env("REDIS_BENCH_PASSWORD")
private let database = envInt("REDIS_BENCH_DATABASE", 0)
private let keyCount = envInt("REDIS_BENCH_KEYS", 1_000_000)
private let pipelineChunk = max(1, envInt("REDIS_BENCH_PIPELINE", 10_000))
private let valueBytes = max(1, envInt("REDIS_BENCH_VALUE_BYTES", 16))
private let latencyIterations = envInt("REDIS_BENCH_LATENCY_ITERATIONS", 10_000)
private let concurrency = max(1, envInt("REDIS_BENCH_CONCURRENCY", 8))
private let modes = envString(
    "REDIS_BENCH_MODES",
    "set_batches,set_pipelined,mset,get_pipelined,mget,set_concurrent,latency_set,latency_get"
).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(concurrency, ProcessInfo.processInfo.activeProcessorCount)))

private func makeCredentials() -> RedisCredentials {
    password.isEmpty ? .none : .password(password)
}

private func resolveDatabase() -> RedisDatabaseIndex {
    (try? RedisDatabaseIndex(max(0, database))) ?? .zero
}

private let client = RedisClient(configuration: .init(
    endpoint: .init(host: host, port: port),
    credentials: makeCredentials(),
    database: resolveDatabase(),
    eventLoopGroup: eventLoopGroup,
    maxConnections: concurrency,
    maxIdleConnections: concurrency
))

private let sampleValue = [UInt8](repeating: UInt8(ascii: "x"), count: valueBytes)

private func makeKey(_ index: Int) -> RedisKey {
    RedisKey("bench:\(index)")
}

private func makePairs(_ count: Int) -> [RedisKeyValuePair] {
    (0..<count).map { RedisKeyValuePair(key: makeKey($0), value: sampleValue) }
}

private func makeKeys(_ count: Int) -> [RedisKey] {
    (0..<count).map { makeKey($0) }
}

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func rate(count: Int, seconds: Double) -> Int {
    seconds > 0 ? Int(Double(count) / seconds) : 0
}

private func summary(_ mode: String, keys: Int, seconds: Double, extra: String) {
    print("[REDIS PERF SWIFT] \(mode) keys=\(keys) elapsed=\(String(format: "%.3f", seconds))s rate=\(rate(count: keys, seconds: seconds))/s \(extra)")
}

private func microsecondsSince(_ start: ContinuousClock.Instant) -> Int64 {
    let duration = ContinuousClock.now - start
    return duration.components.seconds * 1_000_000 + duration.components.attoseconds / 1_000_000_000_000
}

private func percentile(_ sorted: [Int64], _ fraction: Double) -> Int64 {
    if sorted.isEmpty { return 0 }
    let position = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(position, 0), sorted.count - 1)]
}

private func latencySummary(_ mode: String, samples: [Int64]) {
    let sorted = samples.sorted()
    let mean = sorted.isEmpty ? 0 : sorted.reduce(Int64(0), +) / Int64(sorted.count)
    print("[REDIS PERF SWIFT] \(mode) iterations=\(sorted.count) p50=\(percentile(sorted, 0.5))us p95=\(percentile(sorted, 0.95))us p99=\(percentile(sorted, 0.99))us max=\(sorted.last ?? 0)us mean=\(mean)us")
}

private func chunked(_ total: Int, _ size: Int, _ body: (Int, Int) async throws -> Void) async throws {
    var start = 0
    while start < total {
        let end = min(start + size, total)
        try await body(start, end)
        start = end
    }
}

private func resetDatabase() async throws {
    try await client.flushDatabase(.synchronous)
}

private func runSetPipelined() async throws {
    try await resetDatabase()
    let pairs = makePairs(keyCount)
    let start = ContinuousClock.now
    try await chunked(keyCount, pipelineChunk) { lower, upper in
        try await client.setPipelined(Array(pairs[lower..<upper]))
    }
    summary("set_pipelined", keys: keyCount, seconds: elapsedSeconds(start), extra: "pipeline=\(pipelineChunk) value_bytes=\(valueBytes)")
}

private func runMset() async throws {
    try await resetDatabase()
    let pairs = makePairs(keyCount)
    let start = ContinuousClock.now
    try await chunked(keyCount, pipelineChunk) { lower, upper in
        try await client.set(Array(pairs[lower..<upper]))
    }
    summary("mset", keys: keyCount, seconds: elapsedSeconds(start), extra: "pipeline=\(pipelineChunk) value_bytes=\(valueBytes)")
}

private func seedKeys() async throws {
    try await resetDatabase()
    let pairs = makePairs(keyCount)
    try await chunked(keyCount, pipelineChunk) { lower, upper in
        try await client.setPipelined(Array(pairs[lower..<upper]))
    }
}

private func runGetPipelined() async throws {
    try await seedKeys()
    let keys = makeKeys(keyCount)
    let start = ContinuousClock.now
    try await chunked(keyCount, pipelineChunk) { lower, upper in
        _ = try await client.getPipelined(Array(keys[lower..<upper]))
    }
    summary("get_pipelined", keys: keyCount, seconds: elapsedSeconds(start), extra: "pipeline=\(pipelineChunk) value_bytes=\(valueBytes)")
}

private func runMget() async throws {
    try await seedKeys()
    let keys = makeKeys(keyCount)
    let start = ContinuousClock.now
    try await chunked(keyCount, pipelineChunk) { lower, upper in
        _ = try await client.get(Array(keys[lower..<upper]))
    }
    summary("mget", keys: keyCount, seconds: elapsedSeconds(start), extra: "pipeline=\(pipelineChunk) value_bytes=\(valueBytes)")
}

private func runSetBatch(_ size: Int) async throws {
    try await resetDatabase()
    let pairs = makePairs(size)
    let start = ContinuousClock.now
    try await client.setPipelined(pairs)
    summary("set_batch_\(size)", keys: size, seconds: elapsedSeconds(start), extra: "value_bytes=\(valueBytes)")
}

private func runSetBatches() async throws {
    for size in [1, 100, 100_000, 1_000_000] where size <= keyCount || size <= 1_000_000 {
        try await runSetBatch(size)
    }
}

private struct TaskResult: Sendable {

    let keys: Int
    let seconds: Double
}

private func medianRate(_ results: [TaskResult]) -> Int {
    let sorted = results.map { rate(count: $0.keys, seconds: $0.seconds) }.sorted()
    if sorted.isEmpty { return 0 }
    return sorted[sorted.count / 2]
}

private func runSetConcurrent() async throws {
    try await resetDatabase()
    let perTask = keyCount / concurrency
    let wallStart = ContinuousClock.now
    let results = try await withThrowingTaskGroup(of: TaskResult.self, returning: [TaskResult].self) { group in
        for taskIndex in 0..<concurrency {
            group.addTask { try await runConcurrentTask(taskIndex: taskIndex, perTask: perTask) }
        }
        var collected: [TaskResult] = []
        for try await result in group {
            collected.append(result)
        }
        return collected
    }
    let totalKeys = results.reduce(0) { $0 + $1.keys }
    let aggregate = rate(count: totalKeys, seconds: elapsedSeconds(wallStart))
    print("[REDIS PERF SWIFT] set_concurrent tasks=\(concurrency) keys=\(totalKeys) elapsed=\(String(format: "%.3f", elapsedSeconds(wallStart)))s aggregate=\(aggregate)/s per_task_median=\(medianRate(results))/s")
}

private func runConcurrentTask(taskIndex: Int, perTask: Int) async throws -> TaskResult {
    let base = taskIndex * perTask
    let pairs = (0..<perTask).map { RedisKeyValuePair(key: makeKey(base + $0), value: sampleValue) }
    let start = ContinuousClock.now
    try await chunked(perTask, pipelineChunk) { lower, upper in
        try await client.setPipelined(Array(pairs[lower..<upper]))
    }
    return TaskResult(keys: perTask, seconds: elapsedSeconds(start))
}

private func runLatencySet() async throws {
    try await resetDatabase()
    var samples: [Int64] = []
    samples.reserveCapacity(latencyIterations)
    for index in 0..<latencyIterations {
        let start = ContinuousClock.now
        try await client.set(makeKey(index), to: sampleValue)
        samples.append(microsecondsSince(start))
    }
    latencySummary("latency_set", samples: samples)
}

private func runLatencyGet() async throws {
    try await resetDatabase()
    for index in 0..<latencyIterations {
        try await client.set(makeKey(index), to: sampleValue)
    }
    var samples: [Int64] = []
    samples.reserveCapacity(latencyIterations)
    for index in 0..<latencyIterations {
        let start = ContinuousClock.now
        _ = try await client.get(makeKey(index))
        samples.append(microsecondsSince(start))
    }
    latencySummary("latency_get", samples: samples)
}

private let arrayItems = max(1, envInt("REDIS_BENCH_ARRAY_ITEMS", 100))
private let arrayItemBytes = max(0, envInt("REDIS_BENCH_ARRAY_ITEM_BYTES", 0))

private func seedListForArray() async throws -> RedisKey {
    let listKey = RedisKey("bench:list")
    var arguments: [[UInt8]] = [Array("RPUSH".utf8), listKey.bytes]
    let filler = Array(repeating: UInt8(ascii: "a"), count: arrayItemBytes)
    for index in 0..<arrayItems {
        arguments.append(arrayItemBytes > 0 ? filler : Array("item\(index)".utf8))
    }
    _ = try await client.send(RedisCommand(arguments: arguments))
    return listKey
}

private func runCommandArray() async throws {
    try await resetDatabase()
    let listKey = try await seedListForArray()
    let query = RedisCommand(arguments: [Array("LRANGE".utf8), listKey.bytes, Array("0".utf8), Array("-1".utf8)])
    let queries = max(1, keyCount / arrayItems)
    let chunk = max(1, pipelineChunk / arrayItems)
    var observedItems = 0
    let start = ContinuousClock.now
    try await chunked(queries, chunk) { lower, upper in
        let replies = try await client.pipeline(Array(repeating: query, count: upper - lower))
        for reply in replies {
            observedItems += try reply.arrayValue().count
        }
    }
    summary("command_array", keys: observedItems, seconds: elapsedSeconds(start), extra: "arrays=\(queries) items_each=\(arrayItems)")
}

private func runCommandArrayLatency() async throws {
    try await resetDatabase()
    let listKey = try await seedListForArray()
    let query = RedisCommand(arguments: [Array("LRANGE".utf8), listKey.bytes, Array("0".utf8), Array("-1".utf8)])
    var samples: [Int64] = []
    samples.reserveCapacity(latencyIterations)
    for _ in 0..<latencyIterations {
        let start = ContinuousClock.now
        _ = try await client.send(query).arrayValue()
        samples.append(microsecondsSince(start))
    }
    latencySummary("command_array_latency", samples: samples)
}

private func run(_ mode: String) async throws {
    switch mode {
    case "set_pipelined": try await runSetPipelined()
    case "mset": try await runMset()
    case "get_pipelined": try await runGetPipelined()
    case "mget": try await runMget()
    case "set_batches": try await runSetBatches()
    case "set_concurrent": try await runSetConcurrent()
    case "command_array": try await runCommandArray()
    case "command_array_latency": try await runCommandArrayLatency()
    case "latency_set": try await runLatencySet()
    case "latency_get": try await runLatencyGet()
    default: print("[REDIS PERF SWIFT] unknown mode: \(mode)")
    }
}

print("[REDIS PERF SWIFT] config host=\(host) port=\(port) database=\(database) keys=\(keyCount) pipeline=\(pipelineChunk) value_bytes=\(valueBytes) concurrency=\(concurrency) modes=\(modes.joined(separator: ","))")

try await client.warmUp(connections: concurrency)

for mode in modes {
    do {
        try await run(mode)
    } catch {
        print("[REDIS PERF SWIFT] FAIL mode=\(mode) error=\(error)")
    }
}

await client.shutdown()
try await eventLoopGroup.shutdownGracefully()
