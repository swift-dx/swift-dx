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
@testable import DXCore

@Suite
struct JSONParserNumberTests {

    @Test
    func parsesZero() throws {
        #expect(try JSONParser.parse("0") == JSONFixtures.signedInteger(0))
    }

    @Test
    func parsesNegativeInteger() throws {
        #expect(try JSONParser.parse("-42") == JSONFixtures.signedInteger(-42))
    }

    @Test
    func parsesFraction() throws {
        #expect(try JSONParser.parse("3.5") == JSONFixtures.decimal(3.5))
    }

    @Test
    func parsesExponent() throws {
        #expect(try JSONParser.parse("2e3") == JSONFixtures.decimal(2000))
    }

    @Test
    func parsesNegativeExponentWithSign() throws {
        #expect(try JSONParser.parse("-2.5E-2") == JSONFixtures.decimal(-0.025))
    }

    @Test
    func classifiesWholeNumberAsSignedInteger() {
        guard case .number(let number) = JSONFixtures.parsedValue("7") else { Issue.record("not a number"); return }
        #expect(number.form == .signedInteger(7))
    }

    @Test
    func classifiesInt64MaxAsSignedInteger() {
        guard case .number(let number) = JSONFixtures.parsedValue("9223372036854775807") else { Issue.record("not a number"); return }
        #expect(number.form == .signedInteger(9223372036854775807))
    }

    @Test
    func classifiesAboveInt64MaxAsUnsignedInteger() {
        guard case .number(let number) = JSONFixtures.parsedValue("9223372036854775808") else { Issue.record("not a number"); return }
        #expect(number.form == .unsignedInteger(9223372036854775808))
    }

    @Test
    func classifiesAboveUInt64MaxAsDecimal() {
        guard case .number(let number) = JSONFixtures.parsedValue("18446744073709551616") else { Issue.record("not a number"); return }
        #expect(number.hasFractionOrExponent)
    }

    @Test
    func fractionalForm() {
        guard case .number(let number) = JSONFixtures.parsedValue("1.0") else { Issue.record("not a number"); return }
        #expect(number.form == .decimal(1))
    }

    @Test
    func integralDoubleReportsIntegerKind() {
        #expect(JSONFixtures.parsedValue("1.0").kind == .integer)
    }

    @Test
    func equatesIntegerAndIntegralDecimal() {
        #expect(JSONFixtures.parsedValue("1") == JSONFixtures.parsedValue("1.0"))
    }

    @Test
    func equatesIntegerAndExponentForm() {
        #expect(JSONFixtures.parsedValue("100") == JSONFixtures.parsedValue("1e2"))
    }

    @Test
    func distinguishesDifferentNumbers() {
        #expect(JSONFixtures.parsedValue("1") != JSONFixtures.parsedValue("2"))
    }

    @Test
    func distinguishesNumberFromBoolean() {
        #expect(JSONFixtures.parsedValue("1") != JSONFixtures.parsedValue("true"))
    }

    @Test
    func rejectsLeadingPlus() {
        #expect(JSONFixtures.capturedError("+1") == .found(.invalidNumber(byteOffset: 0)))
    }

    @Test
    func rejectsBareDecimalPoint() {
        #expect(JSONFixtures.capturedError("1.") == .found(.unexpectedEndOfInput(byteOffset: 2)))
    }

    @Test
    func rejectsExponentWithoutDigits() {
        #expect(JSONFixtures.capturedError("1e") == .found(.unexpectedEndOfInput(byteOffset: 2)))
    }

    @Test
    func rejectsLoneMinus() {
        #expect(JSONFixtures.capturedError("-") == .found(.unexpectedEndOfInput(byteOffset: 1)))
    }
}
