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

import Foundation

// One row of a ClickHouse `AggregateFunction(func, types...)` column,
// carried as the opaque, function-specific serialized aggregate state.
// SwiftDX does not interpret the state: `bytes` holds exactly the raw
// state blob the server emitted for this row (or that the caller wants
// written), and `signature` is the inner part of the column type string
// (everything between the outer parentheses, e.g. `sum, UInt64`), so the
// full ClickHouse type renders as `AggregateFunction(\(signature))`.
//
// The native wire layout of an AggregateFunction column is the per-row
// states concatenated back to back with no framing: no column prefix, no
// per-row length prefix. The WRITE path therefore concatenates each row's
// `bytes` verbatim. The READ path can only delimit the rows when the
// function's state is fixed-width, because nothing in the byte stream
// marks where one row's state ends; functions with variable-width state
// (uniq, groupArray, quantile, ...) round-trip on WRITE but are not
// generically decodable on READ. `ClickHouseAggregateStateWidth` holds
// the set of signatures SwiftDX can decode.
public struct ClickHouseAggregateState: Sendable, Hashable, Codable {

    public let signature: String
    public let bytes: [UInt8]

    public init(signature: String, bytes: [UInt8]) {
        self.signature = signature
        self.bytes = bytes
    }
}
