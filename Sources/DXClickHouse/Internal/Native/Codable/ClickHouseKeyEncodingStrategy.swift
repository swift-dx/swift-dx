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

// Convert Swift property names to ClickHouse column names during
// encoding. Mirrors the well-known JSONEncoder.KeyEncodingStrategy
// API so callers can rely on familiar semantics.
//
// The default (`useDefaultKeys`) emits the Swift property name
// verbatim — recommended for new schemas where the Swift naming
// matches the ClickHouse column naming.
//
// `convertToSnakeCase` matches Foundation's JSONEncoder behavior:
// `kinesisShardId` becomes `kinesis_shard_id`. Use this when
// migrating from the legacy HTTP/JSONL path which used snake_case
// column conventions.
public enum ClickHouseKeyEncodingStrategy: Sendable {

    case useDefaultKeys
    case convertToSnakeCase

    func apply(to swiftKey: String) -> String {
        switch self {
        case .useDefaultKeys:
            return swiftKey
        case .convertToSnakeCase:
            return ClickHouseKeyConverter.swiftToSnakeCase(swiftKey)
        }
    }

}
