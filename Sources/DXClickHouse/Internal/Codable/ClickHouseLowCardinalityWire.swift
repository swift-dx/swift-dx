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

// Shared wire-format helpers for LowCardinality column serialization. The
// connection copy path and the columnar decoder both derive the index key
// width from the serialization-type word; this is the single definition both
// sides read, so the two readers cannot drift apart and disagree on how many
// bytes each index occupies.
enum ClickHouseLowCardinalityWire {

    // The index key width in bytes is encoded in the low byte of the
    // serialization-type word: code 0/1/2 select 1/2/4-byte keys (UInt8/
    // UInt16/UInt32) and any larger code selects 8-byte (UInt64) keys.
    static func keyWidth(serializationType: UInt64) -> Int {
        let code = serializationType & 0xFF
        if code >= 3 { return 8 }
        return 1 << Int(code)
    }
}
