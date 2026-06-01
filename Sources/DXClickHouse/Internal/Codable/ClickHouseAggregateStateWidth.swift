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

// Per-row state byte width for the fixed-width-state AggregateFunction
// signatures SwiftDX can decode. An AggregateFunction column has no
// per-row framing on the wire, so a row's state can only be delimited
// when the width is constant and known from the function signature.
//
// The supported set is intentionally narrow and verified against live
// ClickHouse: `sum` over the standard numeric inner types promotes to a
// 64-bit accumulator and serializes as a fixed 8-byte little-endian
// state. Signatures outside this set are write-only (the raw passthrough
// emits any state verbatim) and throw on read so a malformed decode can
// never silently mis-slice the column body.
enum ClickHouseAggregateStateWidth {

    static let sumStateWidth = 8

    static func width(signature: String) throws(ClickHouseError) -> Int {
        let parts = parse(signature: signature)
        if parts.function == "sum", isFixedWidthSumArgument(parts.argument) {
            return sumStateWidth
        }
        throw .protocolError(
            stage: "aggregateFunction.read",
            message: "AggregateFunction(\(signature)) has no known fixed-width state; SwiftDX can read AggregateFunction states only for sum over Int8/Int16/Int32/Int64/UInt8/UInt16/UInt32/UInt64/Float32/Float64. Other functions round-trip on write but are read-deferred."
        )
    }

    private static func parse(signature: String) -> (function: String, argument: String) {
        guard let comma = signature.firstIndex(of: ",") else {
            return (signature.trimmed, "")
        }
        let function = String(signature[signature.startIndex..<comma]).trimmed
        let argument = String(signature[signature.index(after: comma)...]).trimmed
        return (function, argument)
    }

    private static func isFixedWidthSumArgument(_ argument: String) -> Bool {
        switch argument {
        case "Int8", "Int16", "Int32", "Int64",
             "UInt8", "UInt16", "UInt32", "UInt64",
             "Float32", "Float64":
            return true
        default:
            return false
        }
    }
}

extension String {

    fileprivate var trimmed: String {
        var view = Substring(self)
        while let first = view.first, first == " " { view = view.dropFirst() }
        while let last = view.last, last == " " { view = view.dropLast() }
        return String(view)
    }
}
