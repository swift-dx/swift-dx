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

/// Outcome of a lookup operation: either a value was found, or it was not.
///
/// Replaces Optional at lookup boundaries so the absent case has a name
/// rather than `nil`. Call sites pattern-match the two cases explicitly;
/// no value falls through silently.
public enum Lookup<Value: Sendable>: Sendable {

    case found(Value)
    case notFound
}

extension Lookup: Equatable where Value: Equatable {}

extension Lookup: Hashable where Value: Hashable {}
