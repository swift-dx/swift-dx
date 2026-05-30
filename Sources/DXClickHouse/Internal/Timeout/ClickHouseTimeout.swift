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

import Foundation

// Internal timeout primitive used by every public ClickHouseClient
// operation. Races a caller-supplied async body against a Task.sleep of
// the supplied Duration. If the body wins, its value (or thrown error)
// is forwarded to the caller. If the sleep wins, the helper throws
// `ClickHouseError.queryTimeout(elapsed:)` and invokes the supplied
// `onTimeout` closure so the connection layer can send a best-effort
// Cancel packet to the server and tear down the in-flight socket.
//
// The body continues to run on its worker queue after the timeout
// fires: the worker queue is single-threaded and we cannot pre-empt
// the blocking recv() / send() syscall it is sitting in. `onTimeout`
// is therefore the mechanism that breaks the worker out — typically
// by calling shutdown() on the socket file descriptor, which causes
// the next recv() to return 0 (EOF), at which point the connection's
// reconnect path resets the socket for the *next* operation. The
// timed-out caller does not wait for the worker to unblock; the
// timeout error is delivered immediately.
enum ClickHouseTimeout {

    @inline(__always)
    static func run<Value: Sendable>(
        timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        body: @escaping @Sendable () async throws -> Value
    ) async throws(ClickHouseError) -> Value {
        let started = ContinuousClock.now
        let outcome: Result<Value, ClickHouseError> = await race(
            timeout: timeout,
            started: started,
            onTimeout: onTimeout,
            body: body
        )
        switch outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func race<Value: Sendable>(
        timeout: Duration,
        started: ContinuousClock.Instant,
        onTimeout: @escaping @Sendable () -> Void,
        body: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, ClickHouseError> {
        await withTaskGroup(of: RaceOutcome<Value>.self) { group in
            group.addTask {
                let bodyResult: Result<Value, ClickHouseError>
                do {
                    let value = try await body()
                    bodyResult = .success(value)
                } catch let error as ClickHouseError {
                    bodyResult = .failure(error)
                } catch {
                    bodyResult = .failure(.protocolError(stage: "timeout.body", message: "\(error)"))
                }
                return .completed(bodyResult)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .deadlineFired
            }
            return await drain(group: &group, started: started, onTimeout: onTimeout)
        }
    }

    private static func drain<Value: Sendable>(
        group: inout TaskGroup<RaceOutcome<Value>>,
        started: ContinuousClock.Instant,
        onTimeout: @escaping @Sendable () -> Void
    ) async -> Result<Value, ClickHouseError> {
        let first = await group.next() ?? .deadlineFired
        switch first {
        case .completed(let bodyResult):
            group.cancelAll()
            return bodyResult
        case .deadlineFired:
            onTimeout()
            group.cancelAll()
            let elapsed = ContinuousClock.now - started
            return .failure(.queryTimeout(elapsed: elapsed))
        }
    }

    private enum RaceOutcome<Value: Sendable>: Sendable {
        case completed(Result<Value, ClickHouseError>)
        case deadlineFired
    }
}
