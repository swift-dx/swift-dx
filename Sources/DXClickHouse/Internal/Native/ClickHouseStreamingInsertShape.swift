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

// Tracks the shape (column names + specs) of the first block in a
// streaming INSERT and validates every subsequent block against it.
// Used by the public streaming INSERT API where blocks arrive lazily
// and cannot be validated upfront.
//
// Access is serial by construction (the streaming closure runs one
// block at a time before awaiting the next), so `@unchecked Sendable`
// is safe.
final class ClickHouseStreamingInsertShape: @unchecked Sendable {

    private enum LockedShape {

        case awaitingFirst
        case locked([(String, ClickHouseColumnSpec)])

    }

    private var shapeState: LockedShape = .awaitingFirst
    private var blockIndex = 0

    func recordAndValidate(block: ClickHouseBlock) throws {
        let shape = block.columns.map { ($0.name, $0.column.spec) }
        switch shapeState {
        case .locked(let expected):
            try ClickHouseClient.compareShapes(blockIndex: blockIndex, expected: expected, actual: shape)
        case .awaitingFirst:
            shapeState = .locked(shape)
        }
        blockIndex += 1
    }

}
