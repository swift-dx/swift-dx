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

import DXJSONSchema
import Foundation

let schemaJSON = #"""
{
  "type": "object",
  "additionalProperties": false,
  "required": ["id", "name", "tags", "price"],
  "properties": {
    "id":     {"type": "integer", "minimum": 1},
    "name":   {"type": "string", "minLength": 1, "maxLength": 100},
    "active": {"type": "boolean"},
    "tags":   {"type": "array", "items": {"type": "string"}, "maxItems": 10},
    "price":  {"type": "number", "minimum": 0},
    "nested": {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}}}
  }
}
"""#

let instanceJSON = #"{"id":42,"name":"widget","active":true,"tags":["a","b","c"],"price":19.99,"nested":{"x":1,"y":2}}"#

let sizes = [1, 10, 100, 1_000, 100_000, 1_000_000]

func seconds(_ duration: ContinuousClock.Duration) -> Double {
    let attos = duration.components
    return Double(attos.seconds) + Double(attos.attoseconds) / 1.0e18
}

func rate(_ count: Int, _ elapsed: Double) -> Int {
    elapsed <= 0 ? 0 : Int(Double(count) / elapsed)
}

func reportLine(_ mode: String, _ count: Int, _ elapsed: Double, _ valid: Int) {
    print("[JSONSCHEMA PERF SWIFT] \(mode) docs=\(count) elapsed=\(String(format: "%.4f", elapsed))s rate=\(rate(count, elapsed))/s valid=\(valid)")
}

func benchPrecompiled(_ compiled: JSONSchema, _ instance: [UInt8], _ count: Int) {
    let clock = ContinuousClock()
    let start = clock.now
    var valid = 0
    for _ in 0 ..< count where compiled.validate(instance).isValid {
        valid += 1
    }
    reportLine("precompiled", count, seconds(clock.now - start), valid)
}

func benchOneShot(_ schema: [UInt8], _ instance: [UInt8], _ count: Int) {
    let clock = ContinuousClock()
    let start = clock.now
    var valid = 0
    for _ in 0 ..< count where oneShotValid(schema, instance) {
        valid += 1
    }
    reportLine("oneshot", count, seconds(clock.now - start), valid)
}

func oneShotValid(_ schema: [UInt8], _ instance: [UInt8]) -> Bool {
    guard let compiled = try? JSONSchema.compile(schema) else { return false }
    return compiled.validate(instance).isValid
}

let benchType = "bench"

func benchRegistry(_ registry: SchemaRegistry, _ instance: [UInt8], _ count: Int) {
    let clock = ContinuousClock()
    let start = clock.now
    var valid = 0
    for _ in 0 ..< count where registry.validate(instance, type: benchType).isValid {
        valid += 1
    }
    reportLine("registry", count, seconds(clock.now - start), valid)
}

func runPrecompiled(_ compiled: JSONSchema, _ instance: [UInt8]) {
    for size in sizes {
        benchPrecompiled(compiled, instance, size)
    }
}

func runOneShot(_ schema: [UInt8], _ instance: [UInt8]) {
    for size in sizes.prefix(4) {
        benchOneShot(schema, instance, size)
    }
}

func runRegistry(_ instance: [UInt8]) {
    guard let registry = makeRegistry() else { return }
    for size in sizes {
        benchRegistry(registry, instance, size)
    }
}

func makeRegistry() -> SchemaRegistry? {
    let registry = SchemaRegistry()
    guard (try? registry.apply([SchemaEnvelope(type: benchType, schema: Array(schemaJSON.utf8))])) != nil else {
        return nil
    }
    return registry
}

let readerThreads = 8
let perReader = 200_000

func runConcurrency(_ instance: [UInt8]) {
    guard let registry = makeRegistry() else { return }
    let clock = ContinuousClock()
    let start = clock.now
    DispatchQueue.concurrentPerform(iterations: readerThreads + 1) { index in
        concurrencyWorker(registry, instance, index)
    }
    let total = readerThreads * perReader
    reportLine("registry_concurrent_reads", total, seconds(clock.now - start), total)
    print("[JSONSCHEMA PERF SWIFT] registry_concurrent final_generation=\(registry.generation.value)")
}

func concurrencyWorker(_ registry: SchemaRegistry, _ instance: [UInt8], _ index: Int) {
    guard index < readerThreads else { return reapplyWorker(registry) }
    readerWorker(registry, instance)
}

func readerWorker(_ registry: SchemaRegistry, _ instance: [UInt8]) {
    for _ in 0 ..< perReader where !registry.validate(instance, type: benchType).isValid {
        print("[JSONSCHEMA PERF SWIFT] FAIL torn read")
    }
}

func reapplyWorker(_ registry: SchemaRegistry) {
    for _ in 0 ..< 2_000 {
        _ = try? registry.apply([SchemaEnvelope(type: benchType, schema: Array(schemaJSON.utf8))])
    }
}

func bulkEnvelopes(_ count: Int) -> [SchemaEnvelope] {
    (0 ..< count).map { SchemaEnvelope(type: "bulk.\($0)", schema: Array(schemaJSON.utf8)) }
}

func runBulkReplace() {
    let registry = SchemaRegistry()
    for count in [10, 100, 1_000, 10_000] {
        benchBulkReplace(registry, count)
    }
}

func benchBulkReplace(_ registry: SchemaRegistry, _ count: Int) {
    let envelopes = bulkEnvelopes(count)
    let clock = ContinuousClock()
    let start = clock.now
    try? registry.apply(envelopes)
    reportLine("bulk_replace", count, seconds(clock.now - start), registry.registeredTypes.count)
}

func runBatchVerify(_ instance: [UInt8]) async {
    guard let registry = makeRegistry() else { return }
    for size in sizes {
        await benchBatchVerify(registry, instance, size)
    }
}

func benchBatchVerify(_ registry: SchemaRegistry, _ instance: [UInt8], _ count: Int) async {
    let requests = (0 ..< count).map { VerificationRequest(id: $0, type: benchType, payload: instance) }
    let clock = ContinuousClock()
    let start = clock.now
    let report = await registry.verify(batch: requests)
    reportLine("batch_verify_parallel", count, seconds(clock.now - start), report.successCount)
}

func runBatchVerifyDistinct(_ template: [UInt8]) async {
    guard let registry = makeRegistry() else { return }
    for size in sizes {
        await benchBatchVerifyDistinct(registry, template, size)
    }
}

func benchBatchVerifyDistinct(_ registry: SchemaRegistry, _ template: [UInt8], _ count: Int) async {
    let requests = (0 ..< count).map { index -> VerificationRequest<Int> in
        var payload = template
        payload[7] = UInt8(0x30 + index % 10)
        return VerificationRequest(id: index, type: benchType, payload: payload)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let report = await registry.verify(batch: requests)
    reportLine("batch_verify_distinct", count, seconds(clock.now - start), report.successCount)
}

func runBulkConcurrency(_ instance: [UInt8]) {
    guard let registry = makeRegistry() else { return }
    let clock = ContinuousClock()
    let start = clock.now
    DispatchQueue.concurrentPerform(iterations: readerThreads + 1) { index in
        concurrencyWorker(registry, instance, index)
    }
    let total = readerThreads * perReader
    reportLine("bulk_replace_concurrent_reads", total, seconds(clock.now - start), total)
    print("[JSONSCHEMA PERF SWIFT] bulk_replace_concurrent final_generation=\(registry.generation.value)")
}

func currentRSSKB() -> Int {
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
    for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, let kilobytes = Int(fields[1]) { return kilobytes }
    }
    return 0
}

func runLeakSoak(_ compiled: JSONSchema, _ instance: [UInt8], _ iterations: Int) {
    var valid = 0
    let sample = max(1, iterations / 40)
    print("[LEAK] start rssKB=\(currentRSSKB())")
    for index in 0 ..< iterations {
        if compiled.validate(instance).isValid { valid += 1 }
        if index % sample == 0 { print("[LEAK] iter=\(index) rssKB=\(currentRSSKB())") }
    }
    print("[LEAK] end iter=\(iterations) rssKB=\(currentRSSKB()) valid=\(valid)")
}

func runRegistryChurn(_ schema: [UInt8], _ instance: [UInt8], _ iterations: Int) {
    let registry = SchemaRegistry()
    let sample = max(1, iterations / 20)
    print("[CHURN] start rssKB=\(currentRSSKB())")
    for index in 0 ..< iterations {
        _ = try? registry.apply([SchemaEnvelope(type: benchType, schema: schema)])
        _ = registry.validate(instance, type: benchType)
        if index % sample == 0 { print("[CHURN] iter=\(index) gen=\(registry.generation.value) rssKB=\(currentRSSKB())") }
    }
    print("[CHURN] end iter=\(iterations) gen=\(registry.generation.value) rssKB=\(currentRSSKB())")
}

func runConcurrentSoak(_ compiled: JSONSchema, _ instance: [UInt8], _ threads: Int, _ rounds: Int, _ perRound: Int) {
    print("[CSOAK] start threads=\(threads) rounds=\(rounds) perRound=\(perRound) rssKB=\(currentRSSKB())")
    for round in 0 ..< rounds {
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for iteration in 0 ..< perRound {
                var payload = instance
                payload[7] = UInt8(0x30 + iteration % 10)
                _ = compiled.validate(payload).isValid
            }
        }
        print("[CSOAK] round=\(round) totalValidations=\((round + 1) * threads * perRound) rssKB=\(currentRSSKB())")
    }
    print("[CSOAK] end rssKB=\(currentRSSKB())")
}

func runConcurrentRegistrySoak(_ schema: [UInt8], _ instance: [UInt8], _ readers: Int, _ rounds: Int, _ perRound: Int) {
    let registry = SchemaRegistry()
    _ = try? registry.apply([SchemaEnvelope(type: benchType, schema: schema)])
    print("[CRSOAK] start readers=\(readers) rounds=\(rounds) perRound=\(perRound) rssKB=\(currentRSSKB())")
    for round in 0 ..< rounds {
        DispatchQueue.concurrentPerform(iterations: readers + 1) { index in
            if index == readers {
                for _ in 0 ..< max(1, perRound / 50) {
                    _ = try? registry.apply([SchemaEnvelope(type: benchType, schema: schema)])
                }
            } else {
                for iteration in 0 ..< perRound {
                    var payload = instance
                    payload[7] = UInt8(0x30 + iteration % 10)
                    _ = registry.validate(payload, type: benchType).isValid
                }
            }
        }
        print("[CRSOAK] round=\(round) gen=\(registry.generation.value) rssKB=\(currentRSSKB())")
    }
    print("[CRSOAK] end gen=\(registry.generation.value) rssKB=\(currentRSSKB())")
}

let schemaBytes = Array(schemaJSON.utf8)
let instanceBytes = Array(instanceJSON.utf8)

guard let warmCompiled = try? JSONSchema.compile(schemaBytes) else {
    print("[JSONSCHEMA PERF SWIFT] FAIL could not compile schema")
    exit(1)
}

if let soak = ProcessInfo.processInfo.environment["DX_LEAK_SOAK"], let iterations = Int(soak) {
    runLeakSoak(warmCompiled, instanceBytes, iterations)
    exit(0)
}
if let churn = ProcessInfo.processInfo.environment["DX_REGISTRY_CHURN"], let iterations = Int(churn) {
    runRegistryChurn(schemaBytes, instanceBytes, iterations)
    exit(0)
}
if let threads = ProcessInfo.processInfo.environment["DX_CONCURRENT_SOAK"], let count = Int(threads) {
    runConcurrentSoak(warmCompiled, instanceBytes, count, 30, 50_000)
    exit(0)
}
if let readers = ProcessInfo.processInfo.environment["DX_CONCURRENT_REGISTRY"], let count = Int(readers) {
    runConcurrentRegistrySoak(schemaBytes, instanceBytes, count, 30, 50_000)
    exit(0)
}

print("[JSONSCHEMA PERF SWIFT] config schema_bytes=\(schemaBytes.count) instance_bytes=\(instanceBytes.count)")
runPrecompiled(warmCompiled, instanceBytes)
runOneShot(schemaBytes, instanceBytes)
runRegistry(instanceBytes)
runConcurrency(instanceBytes)
runBulkReplace()
runBulkConcurrency(instanceBytes)
await runBatchVerify(instanceBytes)
await runBatchVerifyDistinct(instanceBytes)
