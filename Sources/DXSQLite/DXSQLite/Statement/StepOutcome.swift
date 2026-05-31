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

/// The result of advancing a prepared statement one step.
///
/// `sqlite3_step` reports either that a result row is now available or that
/// execution has finished. Modeling the two outcomes as a named enum keeps the
/// raw `SQLITE_ROW` / `SQLITE_DONE` codes out of the public surface and lets
/// callers exhaustively switch without a sentinel.
public enum StepOutcome: Sendable, Equatable {

    case row
    case done
}
