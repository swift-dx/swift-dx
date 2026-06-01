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

/// The non-NULL bytes of a single column value handed to a ``PostgresDecodable``
/// implementation, along with the wire format and the source type OID so a
/// decoder can validate or branch on them. The ``text`` accessor renders the
/// bytes as UTF-8, which is the common path for text-format values.
public struct PostgresDecodingValue: Sendable {

    public let bytes: [UInt8]
    public let format: PostgresFormat
    public let dataTypeObjectID: UInt32

    init(bytes: [UInt8], format: PostgresFormat, dataTypeObjectID: UInt32) {
        self.bytes = bytes
        self.format = format
        self.dataTypeObjectID = dataTypeObjectID
    }

    public var text: String {
        String(decoding: bytes, as: UTF8.self)
    }
}
