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

// Convert ClickHouse column names to Swift property names during
// decoding. Mirrors JSONDecoder.KeyDecodingStrategy so callers can
// rely on familiar semantics.
//
// The default (`useDefaultKeys`) looks up columns by the Swift
// property name verbatim — recommended for new schemas that use
// camelCase / Swift-native naming.
//
// `convertFromSnakeCase` matches Foundation's JSONDecoder behavior:
// when the Swift type asks for `kinesisShardId`, the decoder also
// tries the snake_case variant `kinesis_shard_id`. Use this when
// SELECTing from tables that were created with snake_case column
// conventions.
public enum ClickHouseKeyDecodingStrategy: Sendable {

    case useDefaultKeys
    case convertFromSnakeCase

    // For a Swift property name (e.g., "kinesisShardId"), return the
    // ClickHouse column name to look up. The decoder calls this with
    // the property name; the strategy decides what to look up in the
    // result columns.
    func columnName(forSwiftKey swiftKey: String) -> String {
        switch self {
        case .useDefaultKeys:
            return swiftKey
        case .convertFromSnakeCase:
            return ClickHouseKeyConverter.swiftToSnakeCase(swiftKey)
        }
    }

}
