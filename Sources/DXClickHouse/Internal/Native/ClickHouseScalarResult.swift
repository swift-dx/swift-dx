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

public enum ClickHouseScalarResult<Value: Sendable>: Sendable {

    case value(Value)
    case empty
}

extension ClickHouseScalarResult: Equatable where Value: Equatable {}
