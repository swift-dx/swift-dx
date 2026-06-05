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

// A ClickHouse Decimal column reads into a Foundation.Decimal, but a
// Foundation.Decimal cannot be INSERTED directly: a Decimal(P, S) column
// needs an explicit precision and scale that a Foundation.Decimal does not
// carry. Encoding one used to fail with an opaque "container is not
// supported" message from the Codable fallback. It must instead surface a
// clear, actionable error pointing the caller at ClickHouseDecimal.
@Suite("inserting a Foundation.Decimal field fails with an actionable error")
struct FoundationDecimalEncodeErrorTests {

    private struct Row: Encodable {
        let price: Decimal
    }

    private struct OptionalRow: Encodable {
        let price: Decimal?
    }

    @Test("the error names ClickHouseDecimal as the fix")
    func clearErrorMentionsClickHouseDecimal() {
        var message = "<no error thrown>"
        do {
            _ = try ClickHouseRowEncoder().encode([Row(price: Decimal(12))])
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("ClickHouseDecimal"))
    }

    @Test("a present optional Foundation.Decimal field also names ClickHouseDecimal")
    func optionalDecimalAlsoClear() {
        var message = "<no error thrown>"
        do {
            _ = try ClickHouseRowEncoder().encode([OptionalRow(price: Decimal(34))])
        } catch {
            message = "\(error)"
        }
        #expect(message.contains("ClickHouseDecimal"))
    }
}
