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

// Walks an encoded INSERT block side-by-side with the schema the server
// declared in its sample block, returning a new block whose columns
// have been promoted to match the server's type for each position.
//
// The encoder builds columns from Swift types alone: a Swift `String`
// becomes a `ClickHouseStringColumn`, a `Map<String, String>` becomes
// a `ClickHouseMapColumn(.string, .string)`. The server may declare
// those columns as `LowCardinality(String)`, `Enum8(...)`,
// `Map(LowCardinality(String), String)`, etc. Without promotion the
// server rejects the INSERT with code 53 "Cannot convert ..." and the
// caller sees no client-side context for the gap.
//
// Promotions implemented:
//   String -> LowCardinality(String)        (dedupe into a dictionary)
//   String -> Enum8 / Enum16                (label lookup -> Int code)
//   Map(K, V) -> Map(K', V')                (recurse on K and V)
//   Array(T) -> Array(T')                   (recurse on T)
//   Nullable(T) -> Nullable(T')             (recurse on T)
//   Tuple(...) -> Tuple(...)                (recurse on each element)
//   any X -> X                              (pass-through when specs match)
//
// Anything else throws `insertColumnTypeUnpromotable` pointing at the
// column name and the from/to specs so the caller sees the exact gap
// instead of an opaque server-side error 53.
enum ClickHouseInsertColumnPromoter {

    static func promote(
        block: ClickHouseBlock,
        toMatch sample: ClickHouseBlock
    ) throws -> ClickHouseBlock {
        guard block.columns.count == sample.columns.count else {
            throw ClickHouseError.insertColumnCountMismatch(
                client: block.columns.count,
                server: sample.columns.count
            )
        }
        var promoted: [ClickHouseBlock.NamedColumn] = []
        promoted.reserveCapacity(block.columns.count)
        for index in block.columns.indices {
            let source = block.columns[index]
            let target = sample.columns[index]
            let promotedColumn = try promote(
                column: source.column,
                toMatch: target.column.spec,
                columnName: source.name
            )
            promoted.append(.init(name: source.name, column: promotedColumn))
        }
        return ClickHouseBlock(blockInfo: block.blockInfo, columns: promoted)
    }

    static func promote(
        column source: any ClickHouseColumn,
        toMatch target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> any ClickHouseColumn {
        if source.spec == target {
            return source
        }
        // DateTime / DateTime64 wire bytes do not carry the timezone —
        // it lives only in the type-name metadata. A column the client
        // built with `timezone: .serverDefault` round-trips byte-for-byte against
        // the server's `timezone: "UTC"` (or any other zone), so when
        // the only difference is the metadata we re-stamp the spec
        // rather than failing the INSERT.
        if Self.metadataOnlyDifference(from: source.spec, to: target) {
            return Self.restampSpec(source: source, target: target)
        }
        return try promoteToTarget(source: source, target: target, columnName: columnName)
    }

    private static func metadataOnlyDifference(
        from source: ClickHouseColumnSpec,
        to target: ClickHouseColumnSpec
    ) -> Bool {
        switch (source, target) {
        case (.dateTime, .dateTime):
            return true
        case let (.dateTime64(sourcePrecision, _), .dateTime64(targetPrecision, _)):
            return sourcePrecision == targetPrecision
        default:
            return false
        }
    }

    private static func restampSpec(
        source: any ClickHouseColumn,
        target: ClickHouseColumnSpec
    ) -> any ClickHouseColumn {
        if let integers = source as? ClickHouseFixedWidthIntegerColumn<UInt32> {
            return ClickHouseFixedWidthIntegerColumn<UInt32>(spec: target, values: integers.values)
        }
        return restampSpecInt64OrUInt64(source: source, target: target)
    }

    private static func restampSpecInt64OrUInt64(
        source: any ClickHouseColumn,
        target: ClickHouseColumnSpec
    ) -> any ClickHouseColumn {
        if let integers = source as? ClickHouseFixedWidthIntegerColumn<Int64> {
            return ClickHouseFixedWidthIntegerColumn<Int64>(spec: target, values: integers.values)
        }
        if let integers = source as? ClickHouseFixedWidthIntegerColumn<UInt64> {
            return ClickHouseFixedWidthIntegerColumn<UInt64>(spec: target, values: integers.values)
        }
        return source
    }

    private static func promoteToTarget(
        source: any ClickHouseColumn,
        target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> any ClickHouseColumn {
        switch target {
        case .lowCardinality(let inner):
            let innerColumn = try promote(column: source, toMatch: inner, columnName: columnName)
            return buildLowCardinality(wrapping: innerColumn, innerSpec: inner)
        case .enum8(let values):
            return try promoteToEnum8(source: source, values: values, columnName: columnName, target: target)
        case .enum16(let values):
            return try promoteToEnum16(source: source, values: values, columnName: columnName, target: target)
        case .map(let keySpec, let valueSpec):
            return try promoteMap(source: source, keySpec: keySpec, valueSpec: valueSpec, target: target, columnName: columnName)
        case .array(let inner):
            return try promoteArray(source: source, inner: inner, target: target, columnName: columnName)
        case .nullable(let inner):
            return try promoteNullable(source: source, inner: inner, target: target, columnName: columnName)
        case .tuple(let elementSpecs):
            return try promoteTuple(source: source, elementSpecs: elementSpecs, target: target, columnName: columnName)
        default:
            throw ClickHouseError.insertColumnTypeUnpromotable(
                column: columnName,
                from: source.spec,
                to: target
            )
        }
    }

    private static func buildLowCardinality(
        wrapping inner: any ClickHouseColumn,
        innerSpec: ClickHouseColumnSpec
    ) -> ClickHouseLowCardinalityColumn {
        if let strings = inner as? ClickHouseStringColumn {
            return buildLowCardinalityString(values: strings.values, innerSpec: innerSpec)
        }
        return ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: innerSpec),
            innerSpec: innerSpec,
            dictionary: inner,
            indices: (0..<UInt64(inner.rowCount)).map { $0 }
        )
    }

    private static func buildLowCardinalityString(
        values: [String],
        innerSpec: ClickHouseColumnSpec
    ) -> ClickHouseLowCardinalityColumn {
        var dictionary: [String] = []
        var dictionaryIndex: [String: UInt64] = [:]
        var indices: [UInt64] = []
        indices.reserveCapacity(values.count)
        for value in values {
            if let existing = dictionaryIndex[value] {
                indices.append(existing)
            } else {
                let next = UInt64(dictionary.count)
                dictionaryIndex[value] = next
                dictionary.append(value)
                indices.append(next)
            }
        }
        return ClickHouseLowCardinalityColumn(
            spec: .lowCardinality(of: innerSpec),
            innerSpec: innerSpec,
            dictionary: ClickHouseStringColumn(spec: innerSpec, values: dictionary),
            indices: indices
        )
    }

    private static func promoteToEnum8(
        source: any ClickHouseColumn,
        values: [ClickHouseEnumValue<Int8>],
        columnName: String,
        target: ClickHouseColumnSpec
    ) throws -> ClickHouseFixedWidthIntegerColumn<Int8> {
        if let strings = source as? ClickHouseStringColumn {
            let codes = try encodeEnumLabelsToCodes(strings: strings, values: values, columnName: columnName, type: Int8.self)
            return ClickHouseFixedWidthIntegerColumn<Int8>(spec: target, values: codes)
        }
        if let integers = source as? ClickHouseFixedWidthIntegerColumn<Int8> {
            return ClickHouseFixedWidthIntegerColumn<Int8>(spec: target, values: integers.values)
        }
        throw ClickHouseError.insertColumnTypeUnpromotable(
            column: columnName,
            from: source.spec,
            to: target
        )
    }

    private static func promoteToEnum16(
        source: any ClickHouseColumn,
        values: [ClickHouseEnumValue<Int16>],
        columnName: String,
        target: ClickHouseColumnSpec
    ) throws -> ClickHouseFixedWidthIntegerColumn<Int16> {
        if let strings = source as? ClickHouseStringColumn {
            let codes = try encodeEnumLabelsToCodes(strings: strings, values: values, columnName: columnName, type: Int16.self)
            return ClickHouseFixedWidthIntegerColumn<Int16>(spec: target, values: codes)
        }
        if let integers = source as? ClickHouseFixedWidthIntegerColumn<Int16> {
            return ClickHouseFixedWidthIntegerColumn<Int16>(spec: target, values: integers.values)
        }
        throw ClickHouseError.insertColumnTypeUnpromotable(
            column: columnName,
            from: source.spec,
            to: target
        )
    }

    private static func encodeEnumLabelsToCodes<T: FixedWidthInteger>(
        strings: ClickHouseStringColumn,
        values: [ClickHouseEnumValue<T>],
        columnName: String,
        type: T.Type
    ) throws -> [T] {
        let lookup = enumLookup(values: values)
        var codes: [T] = []
        codes.reserveCapacity(strings.values.count)
        for label in strings.values {
            codes.append(try lookupEnumCode(label: label, lookup: lookup, values: values, columnName: columnName))
        }
        return codes
    }

    private static func lookupEnumCode<T: FixedWidthInteger>(
        label: String,
        lookup: [String: T],
        values: [ClickHouseEnumValue<T>],
        columnName: String
    ) throws -> T {
        guard let code = lookup[label] else {
            throw ClickHouseError.insertEnumUnknownLabel(
                column: columnName,
                label: label,
                allowedLabels: values.map { $0.name }
            )
        }
        return code
    }

    private static func enumLookup<T: FixedWidthInteger>(
        values: [ClickHouseEnumValue<T>]
    ) -> [String: T] {
        var lookup: [String: T] = [:]
        lookup.reserveCapacity(values.count)
        for entry in values {
            lookup[entry.name] = entry.value
        }
        return lookup
    }

    private static func promoteMap(
        source: any ClickHouseColumn,
        keySpec: ClickHouseColumnSpec,
        valueSpec: ClickHouseColumnSpec,
        target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> ClickHouseMapColumn {
        guard let mapColumn = source as? ClickHouseMapColumn else {
            throw ClickHouseError.insertColumnTypeUnpromotable(
                column: columnName,
                from: source.spec,
                to: target
            )
        }
        let promotedKeys = try promote(column: mapColumn.keys, toMatch: keySpec, columnName: columnName + ".keys")
        let promotedValues = try promote(column: mapColumn.values, toMatch: valueSpec, columnName: columnName + ".values")
        return ClickHouseMapColumn(
            spec: target,
            keySpec: keySpec,
            valueSpec: valueSpec,
            offsets: mapColumn.offsets,
            keys: promotedKeys,
            values: promotedValues
        )
    }

    private static func promoteArray(
        source: any ClickHouseColumn,
        inner: ClickHouseColumnSpec,
        target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> ClickHouseArrayColumn {
        guard let arrayColumn = source as? ClickHouseArrayColumn else {
            throw ClickHouseError.insertColumnTypeUnpromotable(
                column: columnName,
                from: source.spec,
                to: target
            )
        }
        let promotedInner = try promote(column: arrayColumn.inner, toMatch: inner, columnName: columnName + ".inner")
        return ClickHouseArrayColumn(
            spec: target,
            elementSpec: inner,
            offsets: arrayColumn.offsets,
            inner: promotedInner
        )
    }

    private static func promoteNullable(
        source: any ClickHouseColumn,
        inner: ClickHouseColumnSpec,
        target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> ClickHouseNullableColumn {
        guard let nullable = source as? ClickHouseNullableColumn else {
            throw ClickHouseError.insertColumnTypeUnpromotable(
                column: columnName,
                from: source.spec,
                to: target
            )
        }
        let promotedInner = try promote(column: nullable.inner, toMatch: inner, columnName: columnName + ".inner")
        return ClickHouseNullableColumn(
            spec: target,
            innerSpec: inner,
            nullMask: nullable.nullMask,
            inner: promotedInner
        )
    }

    private static func promoteTuple(
        source: any ClickHouseColumn,
        elementSpecs: [ClickHouseColumnSpec],
        target: ClickHouseColumnSpec,
        columnName: String
    ) throws -> ClickHouseTupleColumn {
        guard let tuple = source as? ClickHouseTupleColumn,
              tuple.elementSpecs.count == elementSpecs.count else {
            throw ClickHouseError.insertColumnTypeUnpromotable(
                column: columnName,
                from: source.spec,
                to: target
            )
        }
        var elements: [any ClickHouseColumn] = []
        elements.reserveCapacity(elementSpecs.count)
        for index in elementSpecs.indices {
            let promoted = try promote(
                column: tuple.elements[index],
                toMatch: elementSpecs[index],
                columnName: columnName + ".\(index)"
            )
            elements.append(promoted)
        }
        return ClickHouseTupleColumn(
            spec: target,
            elementSpecs: elementSpecs,
            elements: elements,
            rowCount: tuple.rowCount
        )
    }

}
