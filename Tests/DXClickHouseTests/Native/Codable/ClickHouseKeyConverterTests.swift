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
import Testing

@Suite("ClickHouseKeyConverter — camelCase ↔ snake_case")
struct ClickHouseKeyConverterTests {

    @Test(
        "camelCase to snake_case conversion matches the expected ClickHouse column name for representative keys",
        arguments: [
            ("kinesisShardId", "kinesis_shard_id"),
            ("kinesisSequenceNumber", "kinesis_sequence_number"),
            ("recordIndex", "record_index"),
            ("timestamp", "timestamp"),
            ("traceId", "trace_id"),
            ("severityNumber", "severity_number"),
            ("env", "env"),
            ("body", "body"),
            ("scopeName", "scope_name"),
            ("scopeVersion", "scope_version"),
            ("scope2", "scope2"),
            ("a", "a"),
            ("", ""),
            // Acronym-run handling: an uppercase run followed by a
            // lowercase letter splits BEFORE the last uppercase of
            // the run. Pre-fix, the converter produced "my_urlpath"
            // (no second underscore) because it only handled the
            // simple lower-to-upper transition. The doc explicitly
            // promised Foundation-compatible semantics, so any user
            // with a field like `myURLPath` and a column named
            // `my_url_path` would see "column not found" failures.
            ("myURL", "my_url"),
            ("myURLPath", "my_url_path"),
            ("kinesisURLEncoded", "kinesis_url_encoded"),
            ("urlPath", "url_path"),
            ("ABCDef", "a_bc_def"),
        ]
    )
    func swiftToSnakeCase(swift: String, expected: String) {
        let result = ClickHouseKeyConverter.swiftToSnakeCase(swift)
        #expect(result == expected,
                "swift '\(swift)' → expected '\(expected)' but got '\(result)'")
    }

}
