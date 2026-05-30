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

@testable import DXClickHouse
import Foundation
import Testing

@Suite("ClickHouseClient — scalar extractors (helpers used by count, scalarString, etc.)")
struct ClickHouseScalarExtractorTests {

    private static func makeBlock(_ name: String, values: ClickHouseColumnEntry.Values, rowCount: Int) -> ClickHouseSelectBlock {
        ClickHouseSelectBlock(
            rowCount: rowCount,
            columns: [
                ClickHouseSelectColumn(name: name, typeName: "—", values: values)
            ]
        )
    }

    @Test("firstColumnValues returns the first column of the first non-empty block")
    func firstColumnValuesReturnsFirstColumnOfFirstBlock() {
        let block = Self.makeBlock("c", values: .uint64([42, 100]), rowCount: 2)
        let result = ClickHouseClient.firstColumnValues(from: [block])
        guard case .value(let values) = result, case .uint64(let array) = values else {
            Issue.record("expected .value(.uint64)")
            return
        }
        #expect(array == [42, 100])
    }

    @Test("firstColumnValues skips empty blocks and returns the first column of the next non-empty one")
    func firstColumnValuesSkipsEmpty() {
        let empty = ClickHouseSelectBlock(rowCount: 0, columns: [])
        let block = Self.makeBlock("c", values: .uint64([42]), rowCount: 1)
        let result = ClickHouseClient.firstColumnValues(from: [empty, block])
        guard case .value(let values) = result, case .uint64(let array) = values else {
            Issue.record("expected .value(.uint64)")
            return
        }
        #expect(array == [42])
    }

    @Test("firstColumnValues returns .empty when no block has any rows")
    func firstColumnValuesReturnsEmptyForAllEmpty() {
        let empty1 = ClickHouseSelectBlock(rowCount: 0, columns: [])
        let empty2 = ClickHouseSelectBlock(rowCount: 0, columns: [])
        guard case .empty = ClickHouseClient.firstColumnValues(from: [empty1, empty2]) else {
            Issue.record("expected .empty")
            return
        }
    }

    @Test("firstColumnValues returns .empty when given an empty list")
    func firstColumnValuesReturnsEmptyForEmptyList() {
        guard case .empty = ClickHouseClient.firstColumnValues(from: []) else {
            Issue.record("expected .empty")
            return
        }
    }

    @Test("requireScalarUInt64 extracts the value when the column is UInt64")
    func requireScalarUInt64Happy() throws {
        let count = try ClickHouseClient.requireScalarUInt64(.value(.uint64([42])))
        #expect(count == 42)
    }

    @Test("requireScalarUInt64 throws when the column is the wrong type")
    func requireScalarUInt64WrongTypeThrows() {
        var caught: Error?
        do {
            _ = try ClickHouseClient.requireScalarUInt64(.value(.int64([42])))
        } catch {
            caught = error
        }
        guard case ClickHouseError.scalarColumnTypeMismatch(let actual, let expected) = (caught as? ClickHouseError) ?? .poolHasNoEndpoints else {
            Issue.record("expected scalarColumnTypeMismatch")
            return
        }
        #expect(actual == "Int64")
        #expect(expected == "UInt64")
    }

    @Test("requireScalarUInt64 throws scalarQueryReturnedZeroRows when input is .empty")
    func requireScalarUInt64EmptyResultThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.requireScalarUInt64(.empty)
        }
    }

    @Test("requireScalarUInt64 throws scalarQueryReturnedZeroRows when the column has no rows")
    func requireScalarUInt64EmptyArrayThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.requireScalarUInt64(.value(.uint64([])))
        }
    }

    @Test("firstString returns the first row's string when the column is String")
    func firstStringHappy() throws {
        let result = try ClickHouseClient.firstString(.value(.string(["hello", "world"])))
        #expect(result == .value("hello"))
    }

    @Test("firstString returns .empty when the column is empty")
    func firstStringEmpty() throws {
        let result = try ClickHouseClient.firstString(.value(.string([])))
        #expect(result == .empty)
    }

    @Test("firstString returns .empty when input result is .empty (no rows)")
    func firstStringNoRows() throws {
        let result = try ClickHouseClient.firstString(.empty)
        #expect(result == .empty)
    }

    @Test("firstString throws when the column is not String")
    func firstStringWrongTypeThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.firstString(.value(.int32([1, 2])))
        }
    }

    @Test("firstInt64 returns the first row's value when the column is Int64")
    func firstInt64Happy() throws {
        let result = try ClickHouseClient.firstInt64(.value(.int64([Int64.min, Int64.max])))
        #expect(result == .value(Int64.min))
    }

    @Test("firstInt64 throws when the column is not Int64 (e.g. UInt64)")
    func firstInt64WrongTypeThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.firstInt64(.value(.uint64([42])))
        }
    }

    @Test("firstFloat64 returns the first row's value when the column is Float64")
    func firstFloat64Happy() throws {
        let result = try ClickHouseClient.firstFloat64(.value(.float64([.pi, 2.71828])))
        #expect(result == .value(.pi))
    }

    @Test("firstFloat64 throws when the column is Float32")
    func firstFloat64WrongTypeThrows() {
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.firstFloat64(.value(.float32([1.5])))
        }
    }

    @Test("firstUUID returns the first row's UUID when the column is UUID")
    func firstUUIDHappy() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let result = try ClickHouseClient.firstUUID(.value(.uuid([id])))
        #expect(result == .value(id))
    }

    @Test("firstBool returns the first row's value when the column is Bool")
    func firstBoolHappy() throws {
        let result = try ClickHouseClient.firstBool(.value(.bool([true, false])))
        #expect(result == .value(true))
    }

    @Test("firstDateTime returns the first row's Date when the column is DateTime")
    func firstDateTimeHappy() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try ClickHouseClient.firstDateTime(.value(.dateTime([date])))
        #expect(result == .value(date))
    }

    @Test("firstDateTime throws when the column is DateTime64 (precision-bearing variant)")
    func firstDateTimeWrongTypeThrows() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(throws: ClickHouseError.self) {
            try ClickHouseClient.firstDateTime(.value(.dateTime64([date], precision: 3)))
        }
    }

    @Test("scalar mismatch surfaces a precise type name for Nullable columns rather than a generic composite label")
    func scalarMismatchNamesNullableColumnPrecisely() {
        var caught: Error?
        do {
            _ = try ClickHouseClient.firstString(.value(.nullableString(["x"])))
        } catch {
            caught = error
        }
        guard case ClickHouseError.scalarColumnTypeMismatch(let actual, _) = (caught as? ClickHouseError) ?? .poolHasNoEndpoints else {
            Issue.record("expected scalarColumnTypeMismatch")
            return
        }
        #expect(actual == "Nullable(String)", "actualTypeName must name the precise wire type, got \(actual)")
    }

    @Test("scalar mismatch surfaces a precise type name for Array columns rather than a generic composite label")
    func scalarMismatchNamesArrayColumnPrecisely() {
        var caught: Error?
        do {
            _ = try ClickHouseClient.firstInt64(.value(.arrayOfInt64([[1, 2, 3]])))
        } catch {
            caught = error
        }
        guard case ClickHouseError.scalarColumnTypeMismatch(let actual, _) = (caught as? ClickHouseError) ?? .poolHasNoEndpoints else {
            Issue.record("expected scalarColumnTypeMismatch")
            return
        }
        #expect(actual == "Array(Int64)", "actualTypeName must name the precise wire type, got \(actual)")
    }

    @Test("requireScalarUInt64 composes correctly with firstColumnValues across multiple blocks")
    func endToEndCountSimulation() throws {
        let empty = ClickHouseSelectBlock(rowCount: 0, columns: [])
        let resultBlock = Self.makeBlock("c", values: .uint64([8675309]), rowCount: 1)
        let blocks = [empty, resultBlock]
        let result = ClickHouseClient.firstColumnValues(from: blocks)
        let count = try ClickHouseClient.requireScalarUInt64(result)
        #expect(count == 8675309)
    }

}
