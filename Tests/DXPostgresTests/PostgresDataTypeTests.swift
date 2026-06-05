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

import Testing
import DXPostgres

@Suite struct PostgresDataTypeTests {

    private func dataType(forObjectID objectID: UInt32) -> PostgresDataType {
        PostgresColumn(name: "c", dataTypeObjectID: objectID, format: .text).dataType
    }

    @Test func mapsCatalogObjectIdentifiersToNamedTypes() {
        #expect(dataType(forObjectID: 16) == .bool)
        #expect(dataType(forObjectID: 17) == .bytea)
        #expect(dataType(forObjectID: 21) == .int2)
        #expect(dataType(forObjectID: 23) == .int4)
        #expect(dataType(forObjectID: 20) == .int8)
        #expect(dataType(forObjectID: 26) == .objectIdentifier)
        #expect(dataType(forObjectID: 700) == .float4)
        #expect(dataType(forObjectID: 701) == .float8)
        #expect(dataType(forObjectID: 1700) == .numeric)
        #expect(dataType(forObjectID: 25) == .text)
        #expect(dataType(forObjectID: 1043) == .varchar)
        #expect(dataType(forObjectID: 1042) == .bpchar)
        #expect(dataType(forObjectID: 19) == .name)
        #expect(dataType(forObjectID: 114) == .json)
        #expect(dataType(forObjectID: 3802) == .jsonb)
        #expect(dataType(forObjectID: 2950) == .uuid)
        #expect(dataType(forObjectID: 1082) == .date)
        #expect(dataType(forObjectID: 1083) == .time)
        #expect(dataType(forObjectID: 1114) == .timestamp)
        #expect(dataType(forObjectID: 1184) == .timestamptz)
    }

    @Test func carriesUnknownObjectIdentifierVerbatim() {
        #expect(dataType(forObjectID: 987654) == .other(objectID: 987654))
    }
}
