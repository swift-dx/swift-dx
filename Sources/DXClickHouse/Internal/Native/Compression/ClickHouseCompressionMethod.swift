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

// Wire-level compression method byte that prefixes a compressed
// frame's 9-byte header. Naming follows ch-go's `methodEncoding`.
// Internal: the public configuration exposes only the subset the
// encoder can actually produce (see `ClickHouseClient.OutboundCompression`).
// Decoders still need to recognise every byte the server may emit,
// including `.zstd`, so they can reject it with a typed error rather
// than misframe.
enum ClickHouseCompressionMethod: UInt8, Sendable {

    // `uncompressed` (not `none`) avoids collision with `Optional.none`
    // when matching the result of `init(rawValue:)` in a switch.
    case uncompressed = 0x02
    case lz4 = 0x82
    case zstd = 0x90

}
