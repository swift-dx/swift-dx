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

import Dispatch
import Metrics
import Tracing

// Wraps an ambient operation in a client-kind span and feeds swift-metrics
// counters and a duration timer. When no tracer or metrics backend is
// bootstrapped both are no-ops, so the convenience surface carries telemetry that
// an instrumented application picks up automatically while an uninstrumented one
// pays almost nothing. Only the ambient `Postgres` surface is instrumented; the
// pooled client, the direct connection, and the zero-allocation scalar path stay
// off this code so their benchmarked throughput is unchanged.
enum PostgresInstrumentation {

    static func trace<Result: Sendable>(_ operation: String, _ body: @escaping @Sendable () async throws -> Result) async throws(PostgresError) -> Result {
        try await PostgresError.bridge {
            try await traceRethrowing(operation, body)
        }
    }

    static func traceRethrowing<Result: Sendable>(_ operation: String, _ body: @Sendable () async throws -> Result) async throws -> Result {
        Counter(label: "postgres.operations", dimensions: [("operation", operation)]).increment()
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try await spanned(operation, body)
            recordDuration(operation: operation, startNanoseconds: start)
            return result
        } catch {
            recordDuration(operation: operation, startNanoseconds: start)
            Counter(label: "postgres.operation.errors", dimensions: [("operation", operation)]).increment()
            throw error
        }
    }

    private static func spanned<Result: Sendable>(_ operation: String, _ body: @Sendable () async throws -> Result) async throws -> Result {
        try await withSpan("postgres.\(operation)", ofKind: .client) { span in
            if span.isRecording {
                span.attributes["db.system"] = "postgresql"
                span.attributes["db.operation"] = operation
            }
            return try await body()
        }
    }

    private static func recordDuration(operation: String, startNanoseconds: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanoseconds
        Metrics.Timer(label: "postgres.operation.duration", dimensions: [("operation", operation)]).recordNanoseconds(Int64(min(elapsed, UInt64(Int64.max))))
    }
}
