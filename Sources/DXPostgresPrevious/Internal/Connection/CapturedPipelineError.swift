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

// Holds the first error seen while draining a pipelined batch. Every statement in
// the batch must be read to its ReadyForQuery so the connection stays in sync for
// the next caller, so a failure cannot abort the drain loop early; instead the
// first error is captured here and raised once the whole batch has been consumed.
enum CapturedPipelineError {

    case none
    case captured(PostgresError)

    mutating func captureFirst(_ error: PostgresError) {
        guard case .none = self else { return }
        self = .captured(error)
    }

    func throwIfPresent() throws(PostgresError) {
        guard case .captured(let error) = self else { return }
        throw error
    }
}
