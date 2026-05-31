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

/// The kind of row mutation reported to an update hook.
public enum SQLiteChangeOperation: Sendable, Equatable {

    case insert
    case update
    case delete
}
