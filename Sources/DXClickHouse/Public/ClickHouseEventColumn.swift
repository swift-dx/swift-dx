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

public struct ClickHouseEventColumn<Value>: Sendable {

    public let definition: ClickHouseColumnDefinition

    private let makeValues: @Sendable (Value) -> ClickHouseColumnEntry.Values

    public init(definition: ClickHouseColumnDefinition, makeValues: @escaping @Sendable (Value) -> ClickHouseColumnEntry.Values) {
        self.definition = definition
        self.makeValues = makeValues
    }

    public var name: String {
        definition.name
    }

    public var spec: ClickHouseColumnSpec {
        definition.spec
    }

    public var typeName: String {
        definition.typeName
    }

    public func entry(_ value: Value) -> ClickHouseColumnEntry {
        ClickHouseColumnEntry(name: name, values: makeValues(value))
    }

}

extension ClickHouseEventColumn: Equatable {

    public static func == (lhs: ClickHouseEventColumn<Value>, rhs: ClickHouseEventColumn<Value>) -> Bool {
        lhs.definition == rhs.definition
    }

}

extension ClickHouseEventColumn: Hashable {

    public func hash(into hasher: inout Hasher) {
        definition.hash(into: &hasher)
    }

}

public extension ClickHouseEventColumn where Value == String {

    static func fixedString(name: String, length: Int) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .fixedString(length: length))) {
            .fixedString(length: length, [Data($0.utf8)])
        }
    }

    static func lowCardinalityString(name: String) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .lowCardinality(of: .string))) {
            .lowCardinalityString([$0])
        }
    }

    static func string(name: String) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .string)) {
            .string([$0])
        }
    }

    static func json(name: String) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .json)) {
            .json([$0])
        }
    }

}

public extension ClickHouseEventColumn where Value == UInt8 {

    static func uint8(name: String) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .uint8)) {
            .uint8([$0])
        }
    }

}

public extension ClickHouseEventColumn where Value == UInt16 {

    static func uint16(name: String) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .uint16)) {
            .uint16([$0])
        }
    }

}

public extension ClickHouseEventColumn where Value == ClickHouseNanoseconds {

    static func dateTime64Nanoseconds(name: String, precision: Int, timezone: ClickHouseTimezone) -> Self {
        Self(definition: ClickHouseColumnDefinition(name: name, spec: .dateTime64(precision: precision, timezone: timezone))) {
            .dateTime64Nanoseconds([$0], precision: precision)
        }
    }

}
