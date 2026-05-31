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

import CSQLite

// Default conflict resolution when applying a changeset: omit the conflicting
// change rather than overwrite or abort, so applying is non-destructive.
// Capture-free so it can be passed as the @convention(c) xConflict callback.
func dxChangesetConflictThunk(_ context: UnsafeMutableRawPointer?, _ conflictType: Int32, _ iterator: OpaquePointer?) -> Int32 {
    SQLITE_CHANGESET_OMIT
}
