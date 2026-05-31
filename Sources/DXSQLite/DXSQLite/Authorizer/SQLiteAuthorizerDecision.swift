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

/// The verdict an authorizer returns for one attempted action.
///
/// `allow` lets the action proceed. `deny` aborts preparation of the statement
/// with an authorization error, so the whole statement fails before it runs.
/// `ignore` permits the statement to compile but neutralizes this specific
/// action: a denied column read returns NULL instead of its value, and other
/// ignored actions become no-ops. Use `deny` to reject a statement outright and
/// `ignore` to silently redact part of it.
public enum SQLiteAuthorizerDecision: Sendable, Equatable {

    case allow
    case deny
    case ignore
}
