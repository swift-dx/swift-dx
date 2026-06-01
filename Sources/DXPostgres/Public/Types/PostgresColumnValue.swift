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

/// The result of decoding a column whose value may be SQL NULL. A NULL column is
/// ``sqlNull``; a present value is ``value(_:)`` carrying the decoded Swift
/// value. This is what the nullable decode paths return so that "no value" is a
/// named state the compiler forces every caller to handle, never an optional.
public enum PostgresColumnValue<Value: Sendable>: Sendable {

    case sqlNull
    case value(Value)
}

extension PostgresColumnValue: Equatable where Value: Equatable {}
