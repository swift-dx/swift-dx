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

// A single-value Encoder over one column cell, used when the row keyed
// container's encode<T> / encodeIfPresent<T> reaches a value it does not
// natively recognise — chiefly a RawRepresentable enum field, whose
// synthesized encoder writes its RawValue through a single-value container.
// Every encode call forwards to the originating keyed container's typed
// encode for the same key, so the value goes through the one validated
// code path with no duplicated column-handling logic. When `nullable` is
// set (the value came from an Optional field) the forward targets
// encodeIfPresent so the column is registered Nullable(underlying), letting
// absent rows of the same column append a NULL. Keyed and unkeyed nested
// containers are rejected via the shared rejecting containers: a result row
// column holds a single value, not a sub-structure.
struct ClickHouseColumnValueEncoder<ParentKey: CodingKey>: Encoder {

    let container: ClickHouseRowKeyedContainer<ParentKey>
    let key: ParentKey
    let nullable: Bool
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<NestedKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(ClickHouseRowRejectingKeyedContainer<NestedKey>(codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        ClickHouseRowRejectingContainer(codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ClickHouseColumnValueEncodingContainer(container: container, key: key, nullable: nullable, codingPath: codingPath)
    }
}

struct ClickHouseColumnValueEncodingContainer<ParentKey: CodingKey>: SingleValueEncodingContainer {

    var container: ClickHouseRowKeyedContainer<ParentKey>
    let key: ParentKey
    let nullable: Bool
    var codingPath: [CodingKey]

    mutating func encodeNil() throws { try container.encodeNil(forKey: key) }
    mutating func encode(_ value: Bool) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: String) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Double) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Float) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Int) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Int8) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Int16) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Int32) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: Int64) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: UInt) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: UInt8) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: UInt16) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: UInt32) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode(_ value: UInt64) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
    mutating func encode<T: Encodable>(_ value: T) throws { if nullable { try container.encodeIfPresent(value, forKey: key) } else { try container.encode(value, forKey: key) } }
}
