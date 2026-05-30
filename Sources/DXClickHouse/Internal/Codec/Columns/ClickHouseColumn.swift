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

import NIOCore

protocol ClickHouseColumn: Sendable {

    var spec: ClickHouseColumnSpec { get }
    var rowCount: Int { get }
    func encode(into buffer: inout ByteBuffer) throws

    // Wire-format prefix that must appear at the start of the column
    // chunk, before any body bytes. Matches CH's two-phase column
    // serialization on INSERT (`serializeBinaryBulkStatePrefix` then
    // `serializeBinaryBulkWithMultipleStreams`). For most columns
    // this is empty; the default no-op covers them. LowCardinality
    // emits its 8-byte `KeysSerializationVersion` here, and the
    // composite columns (Array, Map, Nullable, Tuple) recurse into
    // their inner columns so a nested LowCardinality's version
    // surfaces at the chunk start rather than inline with the body.
    func encodePrefix(into buffer: inout ByteBuffer) throws

}

extension ClickHouseColumn {

    func encodePrefix(into buffer: inout ByteBuffer) throws {}

}
