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

// The operation name shown on a span attribute and in log metadata. A single
// command carries its verb bytes (the command's first argument) and decodes them
// only when `name` is read; a batch carries a fixed literal. Constructing a label
// on the hot path is a cheap value copy with no string work — the decode happens
// lazily, and only when a log line is actually emitted or a span is recording.
enum RedisOperationLabel: Sendable {

    case verb([UInt8])
    case fixed(StaticString)

    var name: String {
        switch self {
        case .verb(let bytes): String(decoding: bytes, as: UTF8.self).uppercased()
        case .fixed(let literal): String(describing: literal)
        }
    }
}
