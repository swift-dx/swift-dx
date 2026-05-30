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
import Instrumentation
import Tracing

extension ClickHouseClient {

    public func firstColumnValues(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = []
    ) async throws(ClickHouseError) -> ClickHouseScalarResult<ClickHouseColumnEntry.Values> {
        let blocks = try await collectSelectColumns(sql, settings: settings, parameters: parameters)
        return Self.firstColumnValues(from: blocks)
    }

    public func count(
        _ sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = []
    ) async throws(ClickHouseError) -> UInt64 {
        let result = try await firstColumnValues(sql, settings: settings, parameters: parameters)
        do {
            return try Self.requireScalarUInt64(result)
        } catch {
            throw ClickHouseError.translate(error)
        }
    }

    public func scalarString(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> String {
        let result = try await scalarStringIfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarStringIfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<String> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstString(result)
        }
    }

    public func scalarInt64(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> Int64 {
        let result = try await scalarInt64IfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarInt64IfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<Int64> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstInt64(result)
        }
    }

    public func scalarFloat64(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> Double {
        let result = try await scalarFloat64IfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarFloat64IfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<Double> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstFloat64(result)
        }
    }

    public func scalarUUID(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> UUID {
        let result = try await scalarUUIDIfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarUUIDIfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<UUID> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstUUID(result)
        }
    }

    public func scalarBool(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> Bool {
        let result = try await scalarBoolIfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarBoolIfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<Bool> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstBool(result)
        }
    }

    public func scalarDateTime(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> Date {
        let result = try await scalarDateTimeIfAny(sql, settings: settings, parameters: parameters)
        return try Self.requireValue(result)
    }

    public func scalarDateTimeIfAny(_ sql: String, settings: [ClickHouseQuerySetting] = [], parameters: [ClickHouseQueryParameter] = []) async throws(ClickHouseError) -> ClickHouseScalarResult<Date> {
        try await tracedScalar(sql) {
            let result = try await self.firstColumnValues(sql, settings: settings, parameters: parameters)
            return try Self.firstDateTime(result)
        }
    }

    private static func requireValue<Value: Sendable>(_ result: ClickHouseScalarResult<Value>) throws(ClickHouseError) -> Value {
        switch result {
        case .value(let value): return value
        case .empty: throw ClickHouseError.scalarQueryReturnedZeroRows
        }
    }

    private func tracedScalar<T: Sendable>(_ sql: String, _ operation: @Sendable () async throws -> T) async throws(ClickHouseError) -> T {
        try await ClickHouseError.bridge {
            try await InstrumentationSystem.tracer.withSpan(
                "clickhouse.scalar", context: .current ?? .topLevel, ofKind: .client
            ) { span in
                span.attributes["db.system.name"] = "clickhouse"
                span.attributes["db.operation.name"] = "SELECT"
                span.attributes["db.query.text"] = String(sql.prefix(256))
                return try await operation()
            }
        }
    }

    static func firstColumnValues(from blocks: [ClickHouseSelectBlock]) -> ClickHouseScalarResult<ClickHouseColumnEntry.Values> {
        for block in blocks where block.rowCount > 0 {
            guard let first = block.columns.first else { return .empty }
            return .value(first.values)
        }
        return .empty
    }

    static func requireScalarUInt64(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> UInt64 {
        guard case .value(let values) = result else { throw ClickHouseError.scalarQueryReturnedZeroRows }
        let array = try extractUInt64Array(values)
        guard let first = array.first else {
            throw ClickHouseError.scalarQueryReturnedZeroRows
        }
        return first
    }

    private static func extractUInt64Array(_ values: ClickHouseColumnEntry.Values) throws -> [UInt64] {
        guard case .uint64(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "UInt64"
            )
        }
        return array
    }

    static func firstString(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<String> {
        guard case .value(let values) = result else { return .empty }
        guard case .string(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "String"
            )
        }
        return firstElement(array)
    }

    static func firstInt64(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<Int64> {
        guard case .value(let values) = result else { return .empty }
        guard case .int64(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "Int64"
            )
        }
        return firstElement(array)
    }

    static func firstFloat64(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<Double> {
        guard case .value(let values) = result else { return .empty }
        guard case .float64(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "Float64"
            )
        }
        return firstElement(array)
    }

    static func firstUUID(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<UUID> {
        guard case .value(let values) = result else { return .empty }
        guard case .uuid(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "UUID"
            )
        }
        return firstElement(array)
    }

    static func firstBool(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<Bool> {
        guard case .value(let values) = result else { return .empty }
        guard case .bool(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "Bool"
            )
        }
        return firstElement(array)
    }

    static func firstDateTime(_ result: ClickHouseScalarResult<ClickHouseColumnEntry.Values>) throws -> ClickHouseScalarResult<Date> {
        guard case .value(let values) = result else { return .empty }
        guard case .dateTime(let array) = values else {
            throw ClickHouseError.scalarColumnTypeMismatch(
                actualTypeName: typeName(of: values), expectedKind: "DateTime"
            )
        }
        return firstElement(array)
    }

    private static func firstElement<Value: Sendable>(_ array: [Value]) -> ClickHouseScalarResult<Value> {
        guard let first = array.first else { return .empty }
        return .value(first)
    }

    private static func typeName(of values: ClickHouseColumnEntry.Values) -> String {
        switch values {
        case .int8: return "Int8"
        case .int16: return "Int16"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .int128: return "Int128"
        case .uint8: return "UInt8"
        case .uint16: return "UInt16"
        case .uint32: return "UInt32"
        case .uint64: return "UInt64"
        case .uint128: return "UInt128"
        case .int256: return "Int256"
        case .uint256: return "UInt256"
        case .float32: return "Float32"
        case .float64: return "Float64"
        case .bfloat16: return "BFloat16"
        case .string: return "String"
        case .bool: return "Bool"
        case .uuid: return "UUID"
        case .date: return "Date"
        case .date32: return "Date32"
        case .dateTime: return "DateTime"
        case .dateTime64: return "DateTime64"
        case .dateTime64Nanoseconds: return "DateTime64"
        case .fixedString(let length, _): return "FixedString(\(length))"
        case .ipv4: return "IPv4"
        case .ipv6: return "IPv6"
        case .json: return "JSON"
        case .lowCardinalityString: return "LowCardinality(String)"
        case .decimal32: return "Decimal32"
        case .decimal64: return "Decimal64"
        case .decimal128: return "Decimal128"
        case .decimal256: return "Decimal256"
        case .time: return "Time"
        case .time64: return "Time64"
        case .interval: return "Interval"
        case .nullableString: return "Nullable(String)"
        case .nullableInt8: return "Nullable(Int8)"
        case .nullableInt16: return "Nullable(Int16)"
        case .nullableInt32: return "Nullable(Int32)"
        case .nullableInt64: return "Nullable(Int64)"
        case .nullableInt128: return "Nullable(Int128)"
        case .nullableInt256: return "Nullable(Int256)"
        case .nullableUInt8: return "Nullable(UInt8)"
        case .nullableUInt16: return "Nullable(UInt16)"
        case .nullableUInt32: return "Nullable(UInt32)"
        case .nullableUInt64: return "Nullable(UInt64)"
        case .nullableUInt128: return "Nullable(UInt128)"
        case .nullableUInt256: return "Nullable(UInt256)"
        case .nullableFloat32: return "Nullable(Float32)"
        case .nullableFloat64: return "Nullable(Float64)"
        case .nullableBFloat16: return "Nullable(BFloat16)"
        case .nullableBool: return "Nullable(Bool)"
        case .nullableUUID: return "Nullable(UUID)"
        case .nullableDate: return "Nullable(Date)"
        case .nullableDate32: return "Nullable(Date32)"
        case .nullableDateTime: return "Nullable(DateTime)"
        case .nullableDateTime64: return "Nullable(DateTime64)"
        case .nullableDateTime64Nanoseconds: return "Nullable(DateTime64)"
        case .nullableTime: return "Nullable(Time)"
        case .nullableTime64: return "Nullable(Time64)"
        case .nullableDecimal32: return "Nullable(Decimal32)"
        case .nullableDecimal64: return "Nullable(Decimal64)"
        case .nullableDecimal128: return "Nullable(Decimal128)"
        case .nullableDecimal256: return "Nullable(Decimal256)"
        case .nullableFixedString(let length, _): return "Nullable(FixedString(\(length)))"
        case .nullableIPv4: return "Nullable(IPv4)"
        case .nullableIPv6: return "Nullable(IPv6)"
        case .arrayOfString: return "Array(String)"
        case .arrayOfInt8: return "Array(Int8)"
        case .arrayOfInt16: return "Array(Int16)"
        case .arrayOfInt32: return "Array(Int32)"
        case .arrayOfInt64: return "Array(Int64)"
        case .arrayOfUInt8: return "Array(UInt8)"
        case .arrayOfUInt16: return "Array(UInt16)"
        case .arrayOfUInt32: return "Array(UInt32)"
        case .arrayOfUInt64: return "Array(UInt64)"
        case .arrayOfFloat32: return "Array(Float32)"
        case .arrayOfFloat64: return "Array(Float64)"
        case .arrayOfBFloat16: return "Array(BFloat16)"
        case .arrayOfBool: return "Array(Bool)"
        case .arrayOfUUID: return "Array(UUID)"
        case .arrayOfDate: return "Array(Date)"
        case .arrayOfDateTime: return "Array(DateTime)"
        case .arrayOfTupleFloat64Float64: return "Array(Tuple(Float64, Float64))"
        case .arrayOfArrayOfTupleFloat64Float64: return "Array(Array(Tuple(Float64, Float64)))"
        case .arrayOfArrayOfArrayOfTupleFloat64Float64: return "Array(Array(Array(Tuple(Float64, Float64))))"
        case .tupleStringString: return "Tuple(String, String)"
        case .tupleStringInt32: return "Tuple(String, Int32)"
        case .tupleStringInt64: return "Tuple(String, Int64)"
        case .tupleFloat64Float64: return "Tuple(Float64, Float64)"
        case .mapStringString: return "Map(String, String)"
        case .mapStringInt32: return "Map(String, Int32)"
        case .mapStringInt64: return "Map(String, Int64)"
        case .mapStringFloat32: return "Map(String, Float32)"
        case .mapStringFloat64: return "Map(String, Float64)"
        case .mapStringBool: return "Map(String, Bool)"
        case .mapStringUUID: return "Map(String, UUID)"
        case .mapStringDateTime: return "Map(String, DateTime)"
        case .mapInt32String: return "Map(Int32, String)"
        case .mapInt64String: return "Map(Int64, String)"
        case .mapUInt64Int64: return "Map(UInt64, Int64)"
        case .lowCardinalityStringIndexed: return "LowCardinality(String)"
        case .mapStringStringIndexed: return "Map(String, String)"
        }
    }

}
