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
import DXCore
import Foundation
import Testing

// Compile-only checks that every public overload on
// `ClickHouseClient` is wired up and reachable through the
// DXCallback / DXMessageHandler primitives exported by DXCore. These
// tests do not open a broker connection; they simply build closures
// that reference each public symbol so the test target's public-API
// dependency on the overload surface fails fast if a symbol is
// renamed or removed.
@Suite("ClickHouseClient overload surface")
struct ClickHouseClientOverloadSurface {

    struct DemoRow: Codable, Sendable, Equatable {
        let id: UInt64
        let name: String
    }

    final class CapturingHandler: DXMessageHandler, @unchecked Sendable {

        typealias Message = DemoRow
        typealias Failure = ClickHouseError

        var received: [DemoRow] = []
        var errors: [ClickHouseError] = []

        func receive(_ message: DemoRow) async { received.append(message) }
        func receive(error: ClickHouseError) async { errors.append(error) }
    }

    @Test("DXCallback typealias resolves to a result-bearing closure")
    func dxCallbackTypealias() {
        let callback: DXCallback<Int, ClickHouseError> = { result in
            switch result {
            case .success(let value): #expect(value == 7)
            case .failure: Issue.record("unexpected failure")
            }
        }
        callback(.success(7))
    }

    @Test("DXMessageHandler conformance compiles for ClickHouseError")
    func dxMessageHandlerConformance() async {
        let handler = CapturingHandler()
        await handler.receive(DemoRow(id: 1, name: "alice"))
        await handler.receive(error: ClickHouseError.protocolError(stage: "test", message: "demo"))
        #expect(handler.received.count == 1)
        #expect(handler.errors.count == 1)
    }

    // Compile-only reference: forces the linker to keep every overload
    // symbol the surface promises. The function never executes against
    // a live broker; it only needs to type-check.
    @Test("Every overload signature is present on ClickHouseClient")
    func overloadSignaturesExist() {
        let exercise: @Sendable (ClickHouseClient) async throws -> Void = { client in
            try await client.execute("SELECT 1")
            try await client.execute(Array("SELECT 1".utf8))
            try await client.ping()
            _ = try await client.scalar("SELECT toUInt64(1)", as: UInt64.self)
            _ = try await client.scalar(Array("SELECT toUInt64(1)".utf8), as: UInt64.self)
            _ = client.select("SELECT 1", as: UInt8.self)
            _ = client.select(Array("SELECT 1".utf8), as: UInt8.self)
            _ = try await client.selectAll("SELECT 1", as: UInt8.self)
            _ = try await client.selectAll(Array("SELECT 1".utf8), as: UInt8.self)
            let demo = DemoRow(id: 1, name: "a")
            _ = try await client.insert(into: "t", rows: [demo])
            let sequenceRows: [DemoRow] = [demo]
            _ = try await client.insert(into: "t", rows: SequenceWrapper(rows: sequenceRows))
            _ = try await client.insert(into: "t", rows: Self.asyncRowSequence(of: [demo]))
            _ = try await client.insertNativeBlock(into: "t", columnList: "(id)", nativeBlockBytes: [])
            client.execute("SELECT 1") { _ in }
            client.ping { _ in }
            client.scalar("SELECT 1", as: UInt64.self) { _ in }
            client.select("SELECT 1", as: UInt8.self) { _ in }
            client.insert(into: "t", rows: [demo]) { _ in }
            _ = client.stream("SELECT 1", as: DemoRow.self, handler: CapturingHandler())
            _ = client.stream(Array("SELECT 1".utf8), as: DemoRow.self, handler: CapturingHandler())
        }
        _ = exercise
    }

    static func asyncRowSequence(of rows: [DemoRow]) -> AsyncStream<DemoRow> {
        AsyncStream { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }
}

// Concrete Sendable wrapper around an Array<DemoRow>. Mirrors any
// downstream caller that needs to drive the `insert<S: Sequence>`
// overload with their own Sendable container type instead of an
// Array literal.
struct SequenceWrapper: Sequence, Sendable {

    let rows: [ClickHouseClientOverloadSurface.DemoRow]

    func makeIterator() -> Array<ClickHouseClientOverloadSurface.DemoRow>.Iterator {
        rows.makeIterator()
    }
}

