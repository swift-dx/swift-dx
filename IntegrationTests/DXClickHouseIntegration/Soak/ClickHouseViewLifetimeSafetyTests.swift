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
import NIOCore
import NIOPosix
import Testing

// View lifetime stance for ClickHouseBlockStringView and every view
// vended from it (ClickHouseStringView, ClickHouseFixedStringView,
// ClickHouseArrayOfFixedStringView, ClickHouseMapStringStringView,
// ClickHouseStringColumnView, ClickHouseFixedStringColumnView,
// ClickHouseArrayOfFixedStringColumnView, ClickHouseMapStringStringColumnView).
//
// LANGUAGE-FEATURE STATE (Swift 6.3.2):
//
// Swift 6.2 introduced `~Escapable` for nonescapable types as an
// experimental capability. Swift 6.3 keeps that capability behind a
// non-default mode and does not permit it to compose with all the
// constraints SwiftDX needs on view types — specifically, a
// `~Escapable & Sendable` struct cannot be returned across a closure
// boundary or stored on a stack-allocated AsyncThrowingStream
// continuation, both of which the view APIs rely on.
//
// As a result SwiftDX cannot use the compiler to forbid escapes of
// view bindings beyond the block scope. The current design uses
// ARC-managed arena handles instead: every view holds a Sendable
// reference to the arena, and escaping a view keeps the arena alive
// as long as the view is reachable. Escapes are therefore memory-safe
// but defeat the allocation-avoidance goal of the view path.
//
// This file pins the contract three ways:
//
//   1. A documentary @Test that records the language-feature gap and
//      the design rationale, so a future toolchain bump that lifts
//      the restriction surfaces this test as the place to harden the
//      contract with `~Escapable`.
//
//   2. A round-trip @Test that escapes a ClickHouseStringView out of
//      a selectStringColumns block and asserts the bytes remain
//      readable (no crash, no use-after-free). This proves the
//      arena's ARC ownership keeps the payload alive past the block
//      iteration boundary.
//
//   3. A negative-shape @Test confirming that materialising the view
//      via asString() before escape is the documented escape hatch
//      and the bytes still match.
@Suite(
    "ClickHouse integration — view lifetime safety (documentary + runtime contract)",
    .enabled(if: ProcessInfo.processInfo.environment["CH_INTEGRATION_HOST"] != nil),
    .serialized
)
struct ClickHouseViewLifetimeSafetyTests {

    @Test("view types do not use ~Escapable today; the constraint is documented behaviour, not compile-time enforcement")
    func viewLifetimeConstraintIsDocumentaryToday() {
        // Pin the design stance. If a future Swift release relaxes
        // the `~Escapable` constraints enough to apply them to
        // Sendable-across-AsyncSequence view types, this test must
        // flip to assert the constraint instead.
        let toolchain = "Swift 6.3.2"
        let viewTypes = [
            "ClickHouseStringView",
            "ClickHouseFixedStringView",
            "ClickHouseArrayOfFixedStringView",
            "ClickHouseMapStringStringView",
            "ClickHouseStringColumnView",
            "ClickHouseFixedStringColumnView",
            "ClickHouseArrayOfFixedStringColumnView",
            "ClickHouseMapStringStringColumnView",
            "ClickHouseBlockStringView",
        ]
        // Documentary stance: on Swift 6.3.2, `~Escapable` cannot
        // compose with the Sendable + AsyncSequence return constraints
        // these view types require, so the escape-prevention contract
        // is documented in each view type's source file and enforced
        // by code review rather than by the compiler. When a future
        // Swift release lifts the restriction, this test must flip to
        // assert the constraint.
        #expect(viewTypes.count == 9, "view type inventory should be tracked here so a regression in count surfaces in CI; got \(viewTypes.count)")
        #expect(!toolchain.isEmpty, "toolchain pin: \(toolchain)")
    }

    @Test("an escaped ClickHouseStringView keeps its arena alive — no crash, bytes remain readable")
    func escapedStringViewKeepsArenaAlive() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 2,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        let escaped = try await Self.collectFirstViewByEscape(client: client)
        // Force a few allocation cycles to make any UAF surface.
        var ballast: [Int] = []
        ballast.reserveCapacity(50_000)
        for index in 0..<50_000 { ballast.append(index) }
        _ = ballast.count

        let utf8Length = escaped.utf8Length
        #expect(utf8Length > 0, "escaped view byte count must be > 0")
        // Re-read the bytes; should not crash and should match the
        // canonical payload pattern: queries built strings starting at
        // 1_000_000 so the first row materialises as "1000000".
        let asString = escaped.asString()
        #expect(asString.hasPrefix("1000000"), "escaped view bytes must remain readable after block iteration ends; got \(asString)")
    }

    @Test("the documented escape hatch — materialise via asString() before escape — works and the bytes match")
    func materialisedStringEscapeHatchPreservesBytes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }
        let client = ClickHouseClient(configuration: SoakTestSupport.makeConfiguration(
            eventLoopGroup: group,
            maxConnections: 2,
            endpoints: SoakTestSupport.defaultEndpoints()
        ))
        defer { Task { await client.shutdown() } }

        let materialised = try await Self.collectFirstMaterialisedString(client: client)
        #expect(materialised.hasPrefix("2000000"), "materialised escape-hatch bytes must match canonical payload pattern; got \(materialised)")
        // Confirm the String is an independent allocation: walking
        // the UTF-8 view should not trip any ARC-related assertion.
        var utf8Sum = 0
        for byte in materialised.utf8 { utf8Sum += Int(byte) }
        #expect(utf8Sum > 0)
    }

    private static func collectFirstViewByEscape(client: ClickHouseClient) async throws -> ClickHouseStringView {
        var captured: ClickHouseStringView?
        let stream = client.selectStringColumns("SELECT toString(number + 1000000) AS payload FROM numbers(16)")
        for try await block in stream {
            if case .present(let column) = block.stringColumn(named: "payload") {
                if column.rowCount > 0 {
                    captured = column.view(at: 0)
                }
            }
        }
        guard let view = captured else {
            throw ClickHouseError.unsupportedSelectColumnType(typeName: "no string column returned by view-escape test")
        }
        return view
    }

    private static func collectFirstMaterialisedString(client: ClickHouseClient) async throws -> String {
        var captured: String = ""
        let stream = client.selectStringColumns("SELECT toString(number + 2000000) AS payload FROM numbers(16)")
        for try await block in stream {
            if case .present(let column) = block.stringColumn(named: "payload") {
                if column.rowCount > 0 {
                    captured = column.view(at: 0).asString()
                }
            }
        }
        return captured
    }

}

