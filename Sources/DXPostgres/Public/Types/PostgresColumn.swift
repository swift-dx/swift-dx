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

/// A column in a result set: its name, the data type its values carry (both the
/// raw OID and the named ``PostgresDataType`` classification), and the wire
/// format those values use. Every row in the same result shares the same column
/// list.
public struct PostgresColumn: Sendable, Equatable {

    public let name: String
    public let dataTypeObjectID: UInt32
    public let format: PostgresFormat

    public init(name: String, dataTypeObjectID: UInt32, format: PostgresFormat) {
        self.name = name
        self.dataTypeObjectID = dataTypeObjectID
        self.format = format
    }

    init(field: FieldDescription) {
        self.name = field.name
        self.dataTypeObjectID = field.dataTypeObjectID
        self.format = field.format
    }

    public var dataType: PostgresDataType {
        switch dataTypeObjectID {
        case 16: .bool
        case 17: .bytea
        case 21: .int2
        case 23: .int4
        case 20: .int8
        case 26: .objectIdentifier
        case 700: .float4
        case 701: .float8
        case 1700: .numeric
        case 25: .text
        case 1043: .varchar
        case 1042: .bpchar
        case 19: .name
        case 114: .json
        case 3802: .jsonb
        case 2950: .uuid
        case 1082: .date
        case 1083: .time
        case 1114: .timestamp
        case 1184: .timestamptz
        default: .other(objectID: dataTypeObjectID)
        }
    }
}
