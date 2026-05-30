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

// Every typed factory wraps its value in the Field-literal `'value'`
// form because the server's `BaseSettings::read` path calls
// `Field::restoreFromDump` on the wire value: only the String-Field
// dump format is accepted there, and the server then coerces to the
// declared `:Type`. Without quoting, every numeric/bool/uuid/date
// parameter throws `Couldn't restore Field from dump: <raw>`.
@Suite("ClickHouseQueryParameter — typed factory constructors")
struct ClickHouseQueryParameterTypedValuesTests {

    @Test("int8/16/32/64 factories format the value as a single-quoted decimal string")
    func signedIntegerFactories() {
        #expect(ClickHouseQueryParameter.int8(Int8.min, name: "x").value == "'-128'")
        #expect(ClickHouseQueryParameter.int16(0, name: "x").value == "'0'")
        #expect(ClickHouseQueryParameter.int32(Int32.max, name: "x").value == "'2147483647'")
        #expect(ClickHouseQueryParameter.int64(Int64.min, name: "x").value == "'-9223372036854775808'")
        #expect(ClickHouseQueryParameter.int64(Int64.max, name: "x").value == "'9223372036854775807'")
    }

    @Test("uint8/16/32/64 factories format the value as a single-quoted decimal string with no sign")
    func unsignedIntegerFactories() {
        #expect(ClickHouseQueryParameter.uint8(UInt8.max, name: "x").value == "'255'")
        #expect(ClickHouseQueryParameter.uint16(UInt16.max, name: "x").value == "'65535'")
        #expect(ClickHouseQueryParameter.uint32(UInt32.max, name: "x").value == "'4294967295'")
        #expect(ClickHouseQueryParameter.uint64(UInt64.max, name: "x").value == "'18446744073709551615'")
    }

    @Test("int128 / uint128 factories format wide values as single-quoted decimals")
    func wideIntegerFactories() {
        #expect(ClickHouseQueryParameter.int128(Int128.max, name: "x").value == "'170141183460469231731687303715884105727'")
        #expect(ClickHouseQueryParameter.int128(Int128.min, name: "x").value == "'-170141183460469231731687303715884105728'")
        #expect(ClickHouseQueryParameter.uint128(UInt128.max, name: "x").value == "'340282366920938463463374607431768211455'")
        #expect(ClickHouseQueryParameter.uint128(0, name: "x").value == "'0'")
    }

    @Test("float32 / float64 factories use single-quoted Swift String conversion")
    func floatFactories() {
        let pi32 = ClickHouseQueryParameter.float32(Float32(0.5), name: "x")
        #expect(pi32.value == "'0.5'")
        let pi64 = ClickHouseQueryParameter.float64(0.5, name: "x")
        #expect(pi64.value == "'0.5'")
    }

    @Test("string factory wraps the value in single quotes and backslash-escapes embedded quotes/backslashes")
    func stringFactoryQuotesAndEscapes() {
        let plain = ClickHouseQueryParameter.string("hello", name: "label")
        #expect(plain.name == "label")
        #expect(plain.value == "'hello'")

        let withQuote = ClickHouseQueryParameter.string("O'Brien", name: "label")
        #expect(withQuote.value == "'O\\'Brien'")
        let unicode = ClickHouseQueryParameter.string("Aotearoa 🇳🇿", name: "label")
        #expect(unicode.value == "'Aotearoa 🇳🇿'")
    }

    @Test("bool factory uses single-quoted lowercase 'true' and 'false'")
    func boolFactory() {
        #expect(ClickHouseQueryParameter.bool(true, name: "flag").value == "'true'")
        #expect(ClickHouseQueryParameter.bool(false, name: "flag").value == "'false'")
    }

    @Test("uuid factory formats the canonical 8-4-4-4-12 hex string in single-quoted lowercase")
    func uuidFactory() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let parameter = ClickHouseQueryParameter.uuid(id, name: "order_id")
        #expect(parameter.name == "order_id")
        #expect(parameter.value == "'12345678-1234-1234-1234-123456789abc'", "case-folded to lowercase")
    }

    @Test("name field is preserved verbatim across all factory constructors")
    func nameIsPreservedVerbatim() {
        #expect(ClickHouseQueryParameter.int32(1, name: "user_id").name == "user_id")
        #expect(ClickHouseQueryParameter.string("x", name: "Some_Name_42").name == "Some_Name_42")
        #expect(ClickHouseQueryParameter.uuid(UUID(), name: "ξ").name == "ξ", "unicode names pass through")
    }

    @Test("typed-constructor parameter is Equatable to a hand-built one with the same name and quoted value")
    func factoryEqualsRawConstruction() {
        let viaFactory = ClickHouseQueryParameter.int64(42, name: "user_id")
        let viaRaw = ClickHouseQueryParameter(name: "user_id", value: "'42'")
        #expect(viaFactory == viaRaw)
    }

    @Test("typed and raw parameters can coexist in a single array")
    func typedAndRawCoexist() {
        let parameters: [ClickHouseQueryParameter] = [
            .uuid(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "id"),
            .string("active", name: "status"),
            .init(name: "experimental", value: "raw-format"),
        ]
        #expect(parameters.count == 3)
        #expect(parameters[0].value == "'00000000-0000-0000-0000-000000000001'")
        #expect(parameters[1].value == "'active'")
        #expect(parameters[2].value == "raw-format")
    }

    // MARK: - Date / DateTime / DateTime64

    @Test("date factory formats as single-quoted YYYY-MM-DD in UTC regardless of system timezone")
    func dateFactoryFormatsUTC() {
        // 2024-01-15 00:00:00 UTC
        let date = Date(timeIntervalSince1970: 1_705_276_800)
        let parameter = ClickHouseQueryParameter.date(date, name: "d")
        #expect(parameter.value == "'2024-01-15'")
    }

    @Test("date factory at the Unix epoch formats as '1970-01-01'")
    func dateFactoryEpoch() {
        let parameter = ClickHouseQueryParameter.date(Date(timeIntervalSince1970: 0), name: "d")
        #expect(parameter.value == "'1970-01-01'")
    }

    @Test("dateTime factory formats as single-quoted YYYY-MM-DD HH:MM:SS in UTC")
    func dateTimeFactoryFormatsUTC() {
        // 2024-03-15 14:30:45 UTC
        let date = Date(timeIntervalSince1970: 1_710_513_045)
        let parameter = ClickHouseQueryParameter.dateTime(date, name: "ts")
        #expect(parameter.value == "'2024-03-15 14:30:45'")
    }

    @Test("dateTime factory truncates sub-second precision")
    func dateTimeTruncatesSubseconds() {
        // 2024-01-01 00:00:00.500 UTC
        let date = Date(timeIntervalSince1970: 1_704_067_200.500)
        let parameter = ClickHouseQueryParameter.dateTime(date, name: "ts")
        #expect(parameter.value == "'2024-01-01 00:00:00'", "DateTime is whole seconds; sub-second is dropped")
    }

    @Test("dateTime64 factory with precision 0 produces only the second-resolution form (single-quoted)")
    func dateTime64PrecisionZeroOmitsFraction() {
        let date = Date(timeIntervalSince1970: 1_704_067_200.500)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 0)
        #expect(parameter.value == "'2024-01-01 00:00:00'", "precision 0 means no fractional digits")
    }

    @Test("dateTime64 with precision 3 (milliseconds) appends three fractional digits inside the quotes")
    func dateTime64MillisecondPrecision() {
        let date = Date(timeIntervalSince1970: 1_704_067_200.500)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 3)
        #expect(parameter.value == "'2024-01-01 00:00:00.500'")
    }

    @Test("dateTime64 with precision 6 (microseconds) appends six fractional digits inside the quotes")
    func dateTime64MicrosecondPrecision() {
        let date = Date(timeIntervalSince1970: 1_704_067_200.123_456)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 6)
        #expect(parameter.value == "'2024-01-01 00:00:00.123456'")
    }

    @Test("dateTime64 with precision 9 (nanoseconds) appends nine fractional digits inside the quotes")
    func dateTime64NanosecondPrecision() {
        // Date can't carry nanosecond precision faithfully (Double truncates),
        // but the formatter pads with zeros to exactly `precision` digits.
        let date = Date(timeIntervalSince1970: 1_704_067_200.001)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 9)
        #expect(parameter.value.hasPrefix("'2024-01-01 00:00:00."))
        #expect(parameter.value.hasSuffix("'"))
        // The fractional part is exactly 9 chars (padded with zeros).
        let inner = String(parameter.value.dropFirst().dropLast())
        let parts = inner.split(separator: ".")
        #expect(parts.count == 2)
        #expect(parts[1].count == 9, "precision 9 must produce exactly 9 fractional digits")
    }

    @Test("dateTime64 fractional digits are zero-padded when the value has fewer significant digits")
    func dateTime64ZeroPadsFraction() {
        // .005 with precision 3 → "005", not "5"
        let date = Date(timeIntervalSince1970: 1_704_067_200.005)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 3)
        #expect(parameter.value == "'2024-01-01 00:00:00.005'")
    }

    @Test("dateTime64 with sub-second precision on a pre-1970 timestamp produces the correct fractional part — formatter floors toward -infinity, not toward zero")
    func dateTime64PreEpochFractionIsCorrect() {
        // Pre-fix: wholeSeconds used `.towardZero` and fractional used
        // `abs()`, so for `Date(timeIntervalSince1970: -100.7)`
        // (= 1969-12-31T23:58:19.3 UTC) we computed:
        //   secondsPart = "1969-12-31 23:58:19"  (formatter floors)
        //   fractional = abs(-100.7 - (-100)) = 0.7
        //   wire literal = "1969-12-31 23:58:19.700000000"
        // which represents 1969-12-31T23:58:19.7 UTC = -100.3 seconds,
        // off by 0.4 seconds from the input. Any pre-1970 INSERT with
        // fractional precision was silently corrupted.
        //
        // Fix: use `.down` for whole seconds (matching the formatter's
        // calendar-second floor) and compute fractional without `abs`.
        let date = Date(timeIntervalSince1970: -100.7)
        let parameter = ClickHouseQueryParameter.dateTime64(date, name: "ts", precision: 3)
        #expect(parameter.value == "'1969-12-31 23:58:19.300'",
                "fractional 0.3 of the calendar second 23:58:19, not 0.7")
    }

    @Test("dateTime64Ticks with negative ticks (pre-1970 nanoseconds) at precision 9 produces the correct floored second + fractional — Date-based path can't represent ns precision but the ticks-based path can")
    func dateTime64TicksPreEpochNanosecondsLossless() {
        // The Date-based dateTime64 caps at ~microsecond fidelity for
        // sub-second precision (Double epsilon at year-2024 timestamps
        // is ~4e-7), so this test uses the lossless ticks path. The
        // `dateTime64Ticks` factory floor-divides ticks by 10^precision
        // and adjusts the fractional for negative inputs (the
        // pre-existing fix from earlier rounds), so this verifies that
        // pre-1970 nanosecond timestamps round-trip exactly.
        // -100_700_000_000 ticks at precision 9 = -100.7 seconds since
        // epoch = 1969-12-31T23:58:19.3 UTC.
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(-100_700_000_000, name: "ts", precision: 9)
        #expect(parameter.value == "'1969-12-31 23:58:19.300000000'")
    }

    @Test("date factory ignores time-of-day — same day returns the same string")
    func dateIgnoresTimeOfDay() {
        let morning = Date(timeIntervalSince1970: 1_705_276_800)         // 2024-01-15 00:00:00
        let evening = Date(timeIntervalSince1970: 1_705_276_800 + 75600) // 2024-01-15 21:00:00
        let m = ClickHouseQueryParameter.date(morning, name: "d")
        let e = ClickHouseQueryParameter.date(evening, name: "d")
        #expect(m.value == e.value, "Date strips time-of-day")
        #expect(m.value == "'2024-01-15'")
    }

    // MARK: - DateTime64 nanosecond fidelity (ticks variant)

    @Test("dateTime64Ticks at precision 9 preserves exact nanosecond values that Date-based path would lose")
    func dateTime64TicksLosslessNanos() {
        // 2024-01-01 00:00:00.000000001 UTC — one nanosecond past midnight.
        // Date-based path would lose this in Double precision; ticks path
        // should produce the exact string.
        let ticks: Int64 = 1_704_067_200_000_000_001
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 9)
        #expect(parameter.value == "'2024-01-01 00:00:00.000000001'")
    }

    @Test("dateTime64Ticks at precision 9 with all-9-fractional-digits yields exact match")
    func dateTime64TicksFullNineDigits() {
        let ticks: Int64 = 1_704_067_200_123_456_789
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 9)
        #expect(parameter.value == "'2024-01-01 00:00:00.123456789'")
    }

    @Test("dateTime64Ticks at precision 6 (microseconds) formats six fractional digits")
    func dateTime64TicksMicroseconds() {
        // 2024-01-01 00:00:00.123456 UTC at precision 6
        let ticks: Int64 = 1_704_067_200_123_456
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 6)
        #expect(parameter.value == "'2024-01-01 00:00:00.123456'")
    }

    @Test("dateTime64Ticks at precision 0 produces only the single-quoted whole-second form")
    func dateTime64TicksPrecisionZero() {
        // ticks at precision 0 are just whole seconds
        let ticks: Int64 = 1_704_067_200
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 0)
        #expect(parameter.value == "'1704067200'", "precision 0 emits raw ticks (whole seconds), still quoted")
    }

    @Test("dateTime64Ticks is the inverse of the SELECT-side raw Int64 column representation")
    func dateTime64TicksMatchesSelectSideRoundtrip() {
        // The internal column for DateTime64 stores raw Int64 ticks. The
        // SELECT-side mapper hands back those ticks via .nullableDateTime64
        // / dateTime64 (raw values). The parameter ticks variant takes the
        // SAME representation, so SELECT → reformat-as-parameter round-trips.
        let ticks: Int64 = 1_700_000_000_500_000_001  // arbitrary nanosecond-precise instant
        let parameter = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 9)
        // Each character of the fractional part must be preserved exactly.
        let inner = String(parameter.value.dropFirst().dropLast())
        let parts = inner.split(separator: ".")
        #expect(parts.count == 2)
        #expect(parts[1] == "500000001")
    }

    @Test("dateTime64Ticks formats pre-1970 (negative) ticks as the correct calendar instant — Swift's truncating integer division must not corrupt the wire output")
    func dateTime64TicksNegativeTicksPreservedAcrossEpoch() {
        // Pre-fix bug: Swift's `/` and `%` on signed integers truncate
        // toward zero, not toward negative infinity. For ticks = -1 at
        // precision 9 (one nanosecond before epoch), the body computed:
        //   wholeSeconds = -1 / 1_000_000_000 = 0    (wrong: should be -1)
        //   fractional   = -1 % 1_000_000_000 = -1
        //   absFractional = 1
        // The formatter emitted `1970-01-01 00:00:00.000000001` — i.e.,
        // 1ns AFTER epoch instead of 1ns BEFORE. Server-side the row
        // would be silently stored at the wrong instant and a SELECT
        // would never return the original ticks.
        //
        // Correct behavior: the wire literal must read
        // "1969-12-31 23:59:59.999999999" so the server's DateTime64
        // parser stores ticks = -1.

        // Case A: 1 nanosecond before epoch.
        let oneNsBeforeEpoch = ClickHouseQueryParameter.dateTime64Ticks(
            -1, name: "ts", precision: 9
        )
        #expect(oneNsBeforeEpoch.value == "'1969-12-31 23:59:59.999999999'",
                "1ns before epoch must format as 1969-12-31 23:59:59.999999999, got \(oneNsBeforeEpoch.value)")

        // Case B: 1.5 seconds before epoch (precision 9, so ticks = -1_500_000_000).
        // Per the floor-division contract, wholeSeconds must round toward
        // -inf to -2, fractional = +500_000_000, output the fractional 0.5
        // appended to the second-resolution form of -2 seconds.
        let oneAndAHalfBeforeEpoch = ClickHouseQueryParameter.dateTime64Ticks(
            -1_500_000_000, name: "ts", precision: 9
        )
        #expect(oneAndAHalfBeforeEpoch.value == "'1969-12-31 23:59:58.500000000'",
                "1.5s before epoch must format as 1969-12-31 23:59:58.500000000, got \(oneAndAHalfBeforeEpoch.value)")

        // Case C: positive control — precision-9 path still works.
        let oneNsAfterEpoch = ClickHouseQueryParameter.dateTime64Ticks(
            1, name: "ts", precision: 9
        )
        #expect(oneNsAfterEpoch.value == "'1970-01-01 00:00:00.000000001'")
    }

    @Test("dateTime64Ticks is faithful where Date-based path is lossy")
    func dateTime64TicksOutperformsDateBased() {
        // 2024-01-01 + 1 nanosecond. Date can represent this but loses the
        // last few digits in Double precision. Ticks variant preserves it.
        let ticks: Int64 = 1_704_067_200_000_000_001
        let dateApprox = Date(timeIntervalSince1970: TimeInterval(ticks) / 1e9)

        let viaTicks = ClickHouseQueryParameter.dateTime64Ticks(ticks, name: "ts", precision: 9)
        let viaDate = ClickHouseQueryParameter.dateTime64(dateApprox, name: "ts", precision: 9)

        // The ticks-based value is exact.
        #expect(viaTicks.value == "'2024-01-01 00:00:00.000000001'")
        // The Date-based value differs from the ticks value due to Double
        // precision loss (this asserts the documented caveat is real).
        #expect(viaTicks.value != viaDate.value, "Date-based path is lossy past microseconds; ticks is exact")
    }

    @Test("composing parameters across types matches a typical INSERT/SELECT signature")
    func realisticParameterArray() {
        let userId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let parameters: [ClickHouseQueryParameter] = [
            .uuid(userId, name: "user_id"),
            .int32(100, name: "limit"),
            .string("New Zealand", name: "country"),
            .bool(true, name: "include_archived"),
        ]
        let names = parameters.map(\.name)
        let values = parameters.map(\.value)
        #expect(names == ["user_id", "limit", "country", "include_archived"])
        #expect(values == [
            "'11111111-1111-1111-1111-111111111111'",
            "'100'",
            "'New Zealand'",
            "'true'",
        ])
    }

}
