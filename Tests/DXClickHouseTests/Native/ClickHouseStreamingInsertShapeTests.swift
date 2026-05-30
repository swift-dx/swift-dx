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

@testable import DXClickHouse
import Foundation
import Testing

@Suite("ClickHouseStreamingInsertShape — block-shape tracking for streaming INSERT")
struct ClickHouseStreamingInsertShapeTests {

    private static func makeBlock(_ name: String, _ values: [Int32]) -> ClickHouseBlock {
        ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: name,
                column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: values)
            )]
        )
    }

    private static func makeWideBlock() -> ClickHouseBlock {
        ClickHouseBlock(
            blockInfo: .init(),
            columns: [
                .init(name: "n", column: ClickHouseFixedWidthIntegerColumn<Int32>(spec: .int32, values: [1])),
                .init(name: "label", column: ClickHouseStringColumn(values: ["a"]))
            ]
        )
    }

    @Test("the first block establishes the shape and does not throw")
    func firstBlockEstablishesShape() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1, 2, 3]))
    }

    @Test("a second block with matching name and spec passes validation")
    func matchingSecondBlockPasses() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1, 2, 3]))
        try tracker.recordAndValidate(block: Self.makeBlock("n", [4, 5]))
    }

    @Test("a second block with a different column name throws multiBlockStructureMismatch")
    func differentNameThrows() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1]))
        #expect(throws: ClickHouseError.self) {
            try tracker.recordAndValidate(block: Self.makeBlock("m", [2]))
        }
    }

    @Test("a block with a different column count throws multiBlockStructureMismatch")
    func differentColumnCountThrows() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1]))
        #expect(throws: ClickHouseError.self) {
            try tracker.recordAndValidate(block: Self.makeWideBlock())
        }
    }

    @Test("a block with a different column type throws multiBlockStructureMismatch")
    func differentTypeThrows() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1]))
        let int64Block = ClickHouseBlock(
            blockInfo: .init(),
            columns: [.init(
                name: "n",
                column: ClickHouseFixedWidthIntegerColumn<Int64>(spec: .int64, values: [1])
            )]
        )
        #expect(throws: ClickHouseError.self) {
            try tracker.recordAndValidate(block: int64Block)
        }
    }

    @Test("the tracker reports the correct block index in error messages")
    func errorReportsBlockIndex() throws {
        let tracker = ClickHouseStreamingInsertShape()
        try tracker.recordAndValidate(block: Self.makeBlock("n", [1]))
        try tracker.recordAndValidate(block: Self.makeBlock("n", [2]))
        // Now block index = 2; mismatching block 2 should report index 2
        var thrown: Error?
        do {
            try tracker.recordAndValidate(block: Self.makeBlock("m", [3]))
        } catch {
            thrown = error
        }
        guard case ClickHouseError.multiBlockStructureMismatch(let blockIndex, _) = (thrown as? ClickHouseError) ?? .poolHasNoEndpoints else {
            Issue.record("expected multiBlockStructureMismatch")
            return
        }
        #expect(blockIndex == 2)
    }

}
