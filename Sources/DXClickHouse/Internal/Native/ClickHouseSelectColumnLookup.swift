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

// Result of looking up a `ClickHouseSelectColumn` by name on a
// `ClickHouseSelectBlock`. `present` carries the matched column;
// `absent` signals there is no column with that name in the block.
public enum ClickHouseSelectColumnLookup: Sendable {

    case present(ClickHouseSelectColumn)
    case absent

}
