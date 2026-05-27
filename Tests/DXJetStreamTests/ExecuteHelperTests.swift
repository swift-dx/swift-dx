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

import Testing
@testable import DXJetStream

@Suite
struct ExecuteHelperTests {

    @Test
    func asyncExecute_rethrowsTypedJetStreamError() async {
        let outcome: ExecutionOutcome = await runAndAwait {
            throw JetStreamError.notConnected
        }
        switch outcome {
        case .succeeded: Issue.record("expected execute to throw, but it returned success")
        case .threwTyped(let error): #expect(error == .notConnected)
        }
    }

    @Test
    func asyncExecute_wrapsForeignErrorAsTransportError() async {
        let outcome: ExecutionOutcome = await runAndAwait {
            throw ForeignError.boom
        }
        switch outcome {
        case .succeeded: Issue.record("expected execute to throw, but it returned success")
        case .threwTyped(let error):
            switch error {
            case .transportError(let reason): #expect(reason.contains("boom"))
            default: Issue.record("expected transportError, got \(error)")
            }
        }
    }

    @Test
    func asyncExecute_returnsValueWhenBodySucceeds() async {
        let outcome: ExecutionOutcome = await runAndAwait { return () }
        switch outcome {
        case .succeeded: break
        case .threwTyped(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test
    func syncExecute_rethrowsTypedJetStreamError() {
        let outcome: ExecutionOutcome = runSync {
            throw JetStreamError.publishTimedOut
        }
        switch outcome {
        case .succeeded: Issue.record("expected execute to throw, but it returned success")
        case .threwTyped(let error): #expect(error == .publishTimedOut)
        }
    }

    @Test
    func syncExecute_wrapsForeignErrorAsTransportError() {
        let outcome: ExecutionOutcome = runSync {
            throw ForeignError.boom
        }
        switch outcome {
        case .succeeded: Issue.record("expected execute to throw")
        case .threwTyped(let error):
            switch error {
            case .transportError(let reason): #expect(reason.contains("boom"))
            default: Issue.record("expected transportError, got \(error)")
            }
        }
    }

    @Test
    func syncExecute_returnsValueWhenBodySucceeds() {
        let outcome: ExecutionOutcome = runSync { () }
        switch outcome {
        case .succeeded: break
        case .threwTyped(let error): Issue.record("expected success, got \(error)")
        }
    }
}

private enum ForeignError: Error {

    case boom
}

private enum ExecutionOutcome {

    case succeeded
    case threwTyped(JetStreamError)
}

private func runAndAwait(_ body: @Sendable () async throws -> Void) async -> ExecutionOutcome {
    do {
        try await execute { try await body() }
        return .succeeded
    } catch {
        return .threwTyped(error)
    }
}

private func runSync(_ body: () throws -> Void) -> ExecutionOutcome {
    do {
        try execute { try body() }
        return .succeeded
    } catch {
        return .threwTyped(error)
    }
}
