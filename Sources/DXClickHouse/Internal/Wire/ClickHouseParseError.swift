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

// Internal sentinel thrown by the pointer-pure parsing helpers when
// the input is well-formed but incomplete (the caller must read more
// bytes from the socket and retry) versus when the input is structurally
// malformed (the caller must surface a typed protocolError and tear the
// connection down). Kept package-internal so it never leaks into the
// public surface of ClickHouseError; the connection layer is the
// single conversion boundary.
public enum ClickHouseParseError: Error, Equatable, Sendable {

    case needsMoreBytes(stage: String)
    case malformed(stage: String, message: String)
}
