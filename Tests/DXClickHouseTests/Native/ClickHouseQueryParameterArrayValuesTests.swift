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

@Suite("ClickHouseQueryParameter — array(T) typed factory constructors")
struct ClickHouseQueryParameterArrayValuesTests {

    // MARK: - Empty arrays

    @Test("an empty integer array formats as []")
    func emptyIntegerArrayProducesBrackets() {
        let parameter = ClickHouseQueryParameter.arrayInt32([], name: "ids")
        #expect(parameter.value == "[]")
        #expect(parameter.name == "ids")
    }

    @Test("an empty string array formats as []")
    func emptyStringArrayProducesBrackets() {
        let parameter = ClickHouseQueryParameter.arrayString([], name: "tags")
        #expect(parameter.value == "[]")
    }

    // MARK: - Integers

    @Test("arrayInt32 joins values with commas, no spaces")
    func arrayInt32CommaJoined() {
        let parameter = ClickHouseQueryParameter.arrayInt32([10, 20, 30], name: "ids")
        #expect(parameter.value == "[10,20,30]")
    }

    @Test("arrayInt8/16/32/64 preserve negative and boundary values")
    func arraySignedIntegerBoundaries() {
        #expect(ClickHouseQueryParameter.arrayInt8([Int8.min, 0, Int8.max], name: "x").value == "[-128,0,127]")
        #expect(ClickHouseQueryParameter.arrayInt16([-1, 0, 1], name: "x").value == "[-1,0,1]")
        #expect(ClickHouseQueryParameter.arrayInt32([Int32.min, Int32.max], name: "x").value == "[-2147483648,2147483647]")
        #expect(ClickHouseQueryParameter.arrayInt64([Int64.min, Int64.max], name: "x").value == "[-9223372036854775808,9223372036854775807]")
    }

    @Test("arrayUInt8/16/32/64 produce unsigned values without negative signs")
    func arrayUnsignedIntegerBoundaries() {
        #expect(ClickHouseQueryParameter.arrayUInt8([0, UInt8.max], name: "x").value == "[0,255]")
        #expect(ClickHouseQueryParameter.arrayUInt16([UInt16.max], name: "x").value == "[65535]")
        #expect(ClickHouseQueryParameter.arrayUInt32([UInt32.max], name: "x").value == "[4294967295]")
        #expect(ClickHouseQueryParameter.arrayUInt64([UInt64.max], name: "x").value == "[18446744073709551615]")
    }

    @Test("arrayInt32 with a single element produces [v] (no trailing comma)")
    func arrayInt32SingleElement() {
        let parameter = ClickHouseQueryParameter.arrayInt32([42], name: "x")
        #expect(parameter.value == "[42]")
    }

    // MARK: - Floats

    @Test("arrayFloat32 and arrayFloat64 use the standard Swift String conversion")
    func arrayFloatFormatting() {
        #expect(ClickHouseQueryParameter.arrayFloat32([0.5, -1.0], name: "x").value == "[0.5,-1.0]")
        #expect(ClickHouseQueryParameter.arrayFloat64([1.5, 2.5, 3.5], name: "x").value == "[1.5,2.5,3.5]")
    }

    // MARK: - Bool

    @Test("arrayBool uses lowercase true/false")
    func arrayBoolFormatting() {
        let parameter = ClickHouseQueryParameter.arrayBool([true, false, true], name: "flags")
        #expect(parameter.value == "[true,false,true]")
    }

    // MARK: - String

    @Test("arrayString single-quotes each element and joins with commas")
    func arrayStringPlainElements() {
        let parameter = ClickHouseQueryParameter.arrayString(["alpha", "beta", "gamma"], name: "tags")
        #expect(parameter.value == "['alpha','beta','gamma']")
    }

    @Test("arrayString escapes single quotes inside element values")
    func arrayStringEscapesSingleQuotes() {
        let parameter = ClickHouseQueryParameter.arrayString(["O'Brien", "it's"], name: "names")
        #expect(parameter.value == "['O\\'Brien','it\\'s']", "single quotes inside elements escaped to \\'")
    }

    @Test("arrayString escapes backslashes inside element values")
    func arrayStringEscapesBackslashes() {
        let parameter = ClickHouseQueryParameter.arrayString(["C:\\Users\\Sergey"], name: "paths")
        #expect(parameter.value == "['C:\\\\Users\\\\Sergey']")
    }

    @Test("arrayString combines backslash + single-quote escapes correctly (no double-escape)")
    func arrayStringCombinedEscapes() {
        // The backslash escape pass runs FIRST; the resulting string already has
        // doubled backslashes when the quote escape runs, so an input like `\\'`
        // produces `\\\\\\'` — backslash doubled, then quote escaped.
        let parameter = ClickHouseQueryParameter.arrayString(["\\'"], name: "x")
        #expect(parameter.value == "['\\\\\\'']", "input \\' becomes \\\\\\' in the literal")
    }

    @Test("arrayString preserves unicode characters without modification")
    func arrayStringUnicode() {
        let parameter = ClickHouseQueryParameter.arrayString(["Aotearoa", "🇳🇿"], name: "tags")
        #expect(parameter.value == "['Aotearoa','🇳🇿']")
    }

    @Test("arrayString with empty-string elements produces ['','']")
    func arrayStringEmptyElements() {
        let parameter = ClickHouseQueryParameter.arrayString(["", "", ""], name: "x")
        #expect(parameter.value == "['','','']")
    }

    // MARK: - UUID

    @Test("arrayUUID single-quotes each canonical lowercase UUID")
    func arrayUUIDFormatting() {
        let id1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let id2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let parameter = ClickHouseQueryParameter.arrayUUID([id1, id2], name: "ids")
        #expect(parameter.value == "['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222']")
    }

    @Test("arrayUUID lowercases UUIDs even if the source value is uppercase")
    func arrayUUIDLowercases() {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        let parameter = ClickHouseQueryParameter.arrayUUID([id], name: "ids")
        #expect(parameter.value == "['abcdef12-3456-7890-abcd-ef1234567890']")
    }

    // MARK: - Composing in real query shapes

    @Test("array params coexist with scalar params in a typical IN-clause query shape")
    func arrayMixedWithScalarParameters() {
        let userIds: [UInt64] = [1, 2, 3, 4, 5]
        let parameters: [ClickHouseQueryParameter] = [
            .arrayUInt64(userIds, name: "ids"),
            .string("active", name: "status"),
            .int32(100, name: "limit")
        ]
        #expect(parameters[0].value == "[1,2,3,4,5]")
        // Scalar parameters are wrapped in single quotes per the
        // server's Field-restore format (see the catalog tests for
        // why bare values fail with "Couldn't restore Field from
        // dump"). Arrays use bracket-list form which the server
        // parses through Array(T) without the Field-dump path.
        #expect(parameters[1].value == "'active'")
        #expect(parameters[2].value == "'100'")
    }

    // MARK: - Array(Date)

    @Test("arrayDate single-quotes each YYYY-MM-DD value in UTC")
    func arrayDateFormatting() {
        let day1 = Date(timeIntervalSince1970: 1_705_276_800)              // 2024-01-15 00:00:00 UTC
        let day2 = Date(timeIntervalSince1970: 1_705_276_800 + 86_400)     // 2024-01-16 00:00:00 UTC
        let parameter = ClickHouseQueryParameter.arrayDate([day1, day2], name: "ds")
        #expect(parameter.value == "['2024-01-15','2024-01-16']")
    }

    @Test("arrayDate empty array produces []")
    func arrayDateEmpty() {
        #expect(ClickHouseQueryParameter.arrayDate([], name: "x").value == "[]")
    }

    @Test("arrayDate ignores time-of-day on each element")
    func arrayDateIgnoresTime() {
        let d1 = Date(timeIntervalSince1970: 1_705_276_800)                // 2024-01-15 00:00:00 UTC
        let d2 = Date(timeIntervalSince1970: 1_705_276_800 + 75_600)       // 2024-01-15 21:00:00 UTC
        let parameter = ClickHouseQueryParameter.arrayDate([d1, d2], name: "x")
        #expect(parameter.value == "['2024-01-15','2024-01-15']")
    }

    // MARK: - Array(DateTime)

    @Test("arrayDateTime single-quotes each YYYY-MM-DD HH:MM:SS value in UTC")
    func arrayDateTimeFormatting() {
        let ts1 = Date(timeIntervalSince1970: 1_710_513_045)               // 2024-03-15 14:30:45 UTC
        let ts2 = Date(timeIntervalSince1970: 1_710_513_046)               // 2024-03-15 14:30:46 UTC
        let parameter = ClickHouseQueryParameter.arrayDateTime([ts1, ts2], name: "ts")
        #expect(parameter.value == "['2024-03-15 14:30:45','2024-03-15 14:30:46']")
    }

    @Test("arrayDateTime truncates sub-second precision per element")
    func arrayDateTimeTruncatesSubseconds() {
        let ts = Date(timeIntervalSince1970: 1_710_513_045.999)
        let parameter = ClickHouseQueryParameter.arrayDateTime([ts], name: "ts")
        #expect(parameter.value == "['2024-03-15 14:30:45']")
    }

    // MARK: - Array(Int128) / Array(UInt128)

    @Test("arrayInt128 formats wide-integer values as decimal strings, with negatives")
    func arrayInt128Formatting() {
        let values: [Int128] = [Int128.min, 0, Int128.max]
        let parameter = ClickHouseQueryParameter.arrayInt128(values, name: "x")
        #expect(parameter.value == "[-170141183460469231731687303715884105728,0,170141183460469231731687303715884105727]")
    }

    @Test("arrayUInt128 formats wide unsigned values without negative signs")
    func arrayUInt128Formatting() {
        let values: [UInt128] = [0, UInt128.max]
        let parameter = ClickHouseQueryParameter.arrayUInt128(values, name: "x")
        #expect(parameter.value == "[0,340282366920938463463374607431768211455]")
    }

    // MARK: - Realistic shape with mixed array types

    @Test("a SELECT-WHERE shape with both date-array and uuid-array params produces complete server-parsable values")
    func realisticDateAndUuidArrays() {
        let dates: [Date] = [
            Date(timeIntervalSince1970: 1_704_067_200),                    // 2024-01-01
            Date(timeIntervalSince1970: 1_704_067_200 + 86_400 * 30)       // 2024-01-31
        ]
        let ids: [UUID] = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        ]
        let parameters: [ClickHouseQueryParameter] = [
            .arrayDate(dates, name: "ds"),
            .arrayUUID(ids, name: "ids")
        ]
        #expect(parameters[0].value == "['2024-01-01','2024-01-31']")
        #expect(parameters[1].value == "['11111111-1111-1111-1111-111111111111']")
    }

    @Test("a large-array round-trip preserves every element verbatim through the array literal")
    func largeArrayRoundTrip() {
        let values = (0..<100).map { Int32($0) }
        let parameter = ClickHouseQueryParameter.arrayInt32(values, name: "ids")
        // The literal must start with `[0,` and end with `,99]` — order preserved
        #expect(parameter.value.hasPrefix("[0,1,2,"))
        #expect(parameter.value.hasSuffix(",97,98,99]"))
        // Re-parse the comma-separated body to verify length
        let stripped = String(parameter.value.dropFirst().dropLast())
        let parts = stripped.split(separator: ",")
        #expect(parts.count == 100)
    }

}
