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

import DXClickHouse
import Testing

// ClickHouse requires a FixedString length to be a positive integer;
// FixedString(0) is rejected by the server. The encoder rejected
// over-length content but never the declared length itself, so a length of
// 0 produced a FixedString(0) type the server rejects opaquely, and a
// negative length surfaced as a confusing "exceeds FixedString(-5)"
// message. These cases pin the boundary check on the length.
@Suite("FixedString encoder validates the declared length")
struct FixedStringLengthValidationTests {

    struct Row: Codable, Sendable { let code: ClickHouseFixedString }

    private enum Outcome: Sendable, Equatable {
        case encoded
        case rejected(stage: String)
        case otherError(String)
    }

    private static func encode(_ row: Row) -> Outcome {
        do {
            _ = try ClickHouseRowEncoder().encode([row])
            return .encoded
        } catch let error {
            if case .protocolError(let stage, _) = error { return .rejected(stage: stage) }
            return .otherError(String(describing: error))
        }
    }

    @Test("a zero FixedString length is rejected")
    func zeroLengthRejected() {
        let outcome = Self.encode(Row(code: ClickHouseFixedString(bytes: [], length: 0)))
        #expect(outcome == .rejected(stage: "encoder.fixedString"))
    }

    @Test("a negative FixedString length is rejected")
    func negativeLengthRejected() {
        let outcome = Self.encode(Row(code: ClickHouseFixedString(bytes: [], length: -4)))
        #expect(outcome == .rejected(stage: "encoder.fixedString"))
    }

    @Test("a positive FixedString length still encodes")
    func positiveLengthEncodes() {
        let outcome = Self.encode(Row(code: ClickHouseFixedString("AB", length: 4)))
        #expect(outcome == .encoded)
    }
}
