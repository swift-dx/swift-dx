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

// Adapter that exposes a `[ClickHouseBlock]` array as the same
// `next()`-style block source that `insertBlockStream` consumes.
// Lets the array-based and streaming INSERT paths share a single
// implementation in the connection layer.
final class ClickHouseBlockArrayCursor: @unchecked Sendable {

    private let blocks: [ClickHouseBlock]
    private var index = 0

    init(blocks: [ClickHouseBlock]) {
        self.blocks = blocks
    }

    func next() -> ClickHouseBlockCursorOutcome {
        guard index < blocks.count else { return .endOfStream }
        defer { index += 1 }
        return .block(blocks[index])
    }

}

enum ClickHouseBlockCursorOutcome: Sendable {

    case block(ClickHouseBlock)
    case endOfStream

}
