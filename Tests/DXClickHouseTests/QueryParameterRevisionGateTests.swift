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
import Testing

// Server-side query parameters (`{name:Type}` bindings) only exist on the
// wire from protocol revision 54_459. Against an older negotiated
// revision the parameters field must be omitted entirely — but omitting
// it while the caller actually bound parameters silently strips them,
// leaving the placeholders unresolved and surfacing as an opaque
// server-side error. The encoder must instead fail loudly at the
// boundary when there are parameters it cannot transmit, while still
// emitting nothing (and not throwing) when there is nothing to bind.
@Suite("Query parameters fail loudly when the negotiated revision is too old")
struct QueryParameterRevisionGateTests {

    private static let supported = ClickHouseQueryParameters.revisionWithQueryParameters

    @Test("binding parameters against a pre-support revision throws instead of dropping them")
    func tooOldWithParametersThrows() {
        let parameters = ClickHouseQueryParameters([
            .init(name: "id", value: "7"),
            .init(name: "name", value: "widget")
        ])
        var output: [UInt8] = []
        var threw = false
        do {
            try parameters.encode(into: &output, revision: Self.supported - 1)
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(output.isEmpty)
    }

    @Test("no parameters against a pre-support revision is a clean no-op, not an error")
    func tooOldWithoutParametersIsSilentSkip() throws {
        var output: [UInt8] = []
        try ClickHouseQueryParameters.empty.encode(into: &output, revision: Self.supported - 1)
        #expect(output.isEmpty)
    }

    @Test("parameters at the supporting revision are emitted with a terminator")
    func supportedRevisionEmits() throws {
        let parameters = ClickHouseQueryParameters([.init(name: "id", value: "7")])
        var output: [UInt8] = []
        try parameters.encode(into: &output, revision: Self.supported)
        #expect(!output.isEmpty)
        #expect(output.last == 0)
    }
}
