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

// Defensive Encoder stand-in. Returned from `superEncoder` paths so
// any attempt to use the inheritance escape hatch surfaces as a
// typed throw rather than silently encoding into a void.
struct ClickHouseRowRejectingEncoder: Encoder {

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let message: String

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        return KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<Key>(codingPath: codingPath, message: message))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath, message: message)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath, message: message)
    }

}
