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

// Result of a typed `insertStream` batch callback. `endOfStream`
// cleanly terminates the streaming INSERT; `batch` carries the next
// set of rows — an empty array is a legal "skip this tick" signal
// that does not end the stream.
public enum ClickHouseRowBatchOutcome<Row: Sendable>: Sendable {

    case batch([Row])
    case endOfStream

}
