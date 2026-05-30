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
import NIOConcurrencyHelpers
import NIOCore

// Backs both `FixedString(N)` and `IPv6` on the wire (IPv6 is exactly
// 16 raw bytes, sharing the FixedString format). The owning spec is
// preserved so the registry can return the semantically correct spec
// even when two specs share a wire representation.
//
// Storage on SELECT is a single contiguous `[UInt8]` arena of
// `rowCount * length` bytes — one bulk `readBytes` call out of the
// wire-decoded ByteBuffer. The legacy `[Data]` view materialises on
// first read of `values` and is cached so subsequent reads are O(1).
// Callers that reach for the new view API (`fixedStringView(at:)`)
// pay zero per-row allocation; only the eager `values` reader and
// the existing `ClickHouseColumnEntry.Values.fixedString` mapping
// build the `[Data]` representation.
//
// INSERT continues to accept `[Data]` directly because INSERT
// callers construct columns from Swift-side payloads and the encode
// path walks the array once. The two construction paths are
// distinguished by initialiser.
struct ClickHouseFixedStringColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    let length: Int
    private let storage: Storage

    var rowCount: Int { storage.rowCount }
    var values: [Data] { storage.resolvedValues }

    // True when the column was decoded from the wire and the arena is
    // still available for zero-copy views. Eager columns built from
    // `[Data]` have no arena to vend views from; callers must fall
    // back to `values` in that case.
    var hasArena: Bool { storage.hasArena }

    init(spec: ClickHouseColumnSpec, length: Int, values: [Data]) {
        self.spec = spec
        self.length = length
        self.storage = Storage(eager: values, length: length)
    }

    init(spec: ClickHouseColumnSpec, length: Int, deferredArena arena: [UInt8]) {
        self.spec = spec
        self.length = length
        self.storage = Storage(deferredArena: arena, length: length)
    }

    func encode(into buffer: inout ByteBuffer) throws {
        guard length > 0 else {
            throw ClickHouseError.invalidFixedStringLength(length)
        }
        buffer.reserveCapacity(minimumWritableBytes: rowCount * length)
        for value in values {
            try writeFixedRow(value, into: &buffer)
        }
    }

    private func writeFixedRow(_ value: Data, into buffer: inout ByteBuffer) throws {
        guard value.count == length else {
            throw ClickHouseError.fixedStringLengthMismatch(expected: length, actual: value.count)
        }
        buffer.writeBytes(value)
    }

    static func decode(spec: ClickHouseColumnSpec, length: Int, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        guard length > 0 else {
            throw ClickHouseError.invalidFixedStringLength(length)
        }
        let needed = try requireFixedStringCapacity(rows: rows, length: length, available: buffer.readableBytes)
        let arenaBytes = buffer.readBytes(length: needed) ?? []
        return .init(spec: spec, length: length, deferredArena: arenaBytes)
    }

    private static func requireFixedStringCapacity(rows: Int, length: Int, available: Int) throws -> Int {
        let (needed, overflow) = rows.multipliedReportingOverflow(by: length)
        guard !overflow, available >= needed else {
            throw ClickHouseError.truncatedBuffer(
                needed: overflow ? Int.max : needed,
                available: available
            )
        }
        return needed
    }

    // Build a zero-copy view for the given row. Requires the column
    // to have been wire-decoded (i.e. backed by an arena). Eager
    // columns constructed from `[Data]` will trap; the caller is
    // expected to gate access through `hasArena`.
    func fixedStringView(at rowIndex: Int) -> ClickHouseFixedStringView {
        storage.fixedStringView(at: rowIndex)
    }

    // Build a full-column view backed by the same arena. The returned
    // view owns a shared reference to the arena, so it keeps the
    // bytes alive independently of this column instance.
    func makeColumnView(name: String) -> ClickHouseFixedStringColumnView {
        storage.makeColumnView(name: name)
    }

    // Expose the underlying arena handle for inner-column consumers
    // (e.g. an outer ArrayColumn vending Array(FixedString) views).
    func arenaHandle() -> ClickHouseFixedStringArena {
        storage.arenaHandle
    }

    final class Storage: @unchecked Sendable {

        private let lock = NIOLock()
        private let source: Source
        private var state: State
        let arenaHandle: ClickHouseFixedStringArena
        private let length: Int

        var rowCount: Int { arenaHandle.rowCount == 0 ? eagerRowCount : arenaHandle.rowCount }

        var hasArena: Bool {
            switch source {
            case .eager: return false
            case .deferred: return true
            }
        }

        private var eagerRowCount: Int {
            switch source {
            case .eager(let values): return values.count
            case .deferred: return 0
            }
        }

        init(eager values: [Data], length: Int) {
            self.source = .eager(values)
            self.state = .resolved(values)
            self.length = length
            self.arenaHandle = ClickHouseFixedStringArena(bytes: [], fixedWidth: length)
        }

        init(deferredArena arena: [UInt8], length: Int) {
            self.source = .deferred(arena: arena)
            self.state = .pending
            self.length = length
            self.arenaHandle = ClickHouseFixedStringArena(bytes: arena, fixedWidth: length)
        }

        var resolvedValues: [Data] {
            lock.withLock { resolveLocked() }
        }

        func fixedStringView(at rowIndex: Int) -> ClickHouseFixedStringView {
            ClickHouseFixedStringView(arena: arenaHandle, rowIndex: rowIndex)
        }

        func makeColumnView(name: String) -> ClickHouseFixedStringColumnView {
            ClickHouseFixedStringColumnView(name: name, arena: arenaHandle)
        }

        private func resolveLocked() -> [Data] {
            switch state {
            case .resolved(let values): return values
            case .pending:
                let built = Self.buildValues(from: source, length: length)
                state = .resolved(built)
                return built
            }
        }

        private static func buildValues(from source: Source, length: Int) -> [Data] {
            switch source {
            case .eager(let values): return values
            case .deferred(let arena):
                return materialise(arena: arena, length: length)
            }
        }

        private static func materialise(arena: [UInt8], length: Int) -> [Data] {
            guard length > 0 else { return [] }
            let count = arena.count / length
            var result: [Data] = []
            result.reserveCapacity(count)
            arena.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for index in 0..<count {
                    result.append(Data(bytes: base.advanced(by: index * length), count: length))
                }
            }
            return result
        }

        // Construction-time shape of the column. Eager carries the
        // caller-provided `[Data]` for INSERT-side or test
        // construction; deferred carries the wire-decoded arena and
        // defers `[Data]` materialisation until the first reader.
        private enum Source: Sendable {

            case eager([Data])
            case deferred(arena: [UInt8])

        }

        // Materialisation state. `.pending` means the values have not
        // been computed yet; `.resolved` carries the cached snapshot.
        private enum State: Sendable {

            case pending
            case resolved([Data])

        }

    }

}
