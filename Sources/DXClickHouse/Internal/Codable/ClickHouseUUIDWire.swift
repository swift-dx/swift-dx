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

// ClickHouse stores a UUID as two little-endian 8-byte halves, so the wire
// byte order is each half of the text-form bytes reversed. The conversion is
// its own inverse (reversing each half twice restores the original), so the
// same half-reversal serves both directions. Shared so the scalar/array
// decode, the tuple-element decode, and the array encode all agree.
enum ClickHouseUUIDWire {

    static func wireBytes(from uuid: UUID) -> [UInt8] {
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return Array(bytes[0..<8].reversed()) + Array(bytes[8..<16].reversed())
    }

    static func uuid(fromWire bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[7], bytes[6], bytes[5], bytes[4], bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[15], bytes[14], bytes[13], bytes[12], bytes[11], bytes[10], bytes[9], bytes[8]
        ))
    }
}
