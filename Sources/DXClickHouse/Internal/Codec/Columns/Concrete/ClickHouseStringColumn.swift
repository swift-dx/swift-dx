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

import NIOConcurrencyHelpers
import NIOCore

// Backs both `String` and `JSON` on the wire (JSON values are
// length-prefixed UTF-8, identical to String). The owning spec is
// preserved so the registry can hand back the semantically correct
// spec, and INSERT sends the right type name on the wire.
//
// On SELECT the column stores wire bytes contiguously in a single
// `[UInt8]` arena plus a `[Int]` offsets array (length = rowCount + 1).
// The `[String]` view is built lazily on first `values` read and
// snapshotted via a reference-backed resolver, so a `selectColumns`
// caller that never inspects the string body (a wire-only counter,
// or a typed-build path that only touches integer columns) pays one
// arena allocation and zero per-row String heap allocations.
//
// On INSERT or when callers construct the column explicitly with
// `[String]` data, the eager initializer captures the strings as-is
// and re-vends them on `values` without copying. The encode path
// always walks the strings, so deferral would not help there.
struct ClickHouseStringColumn: ClickHouseColumn {

    let spec: ClickHouseColumnSpec
    private let storage: Storage

    var rowCount: Int { storage.rowCount }
    var values: [String] { storage.resolvedValues }

    // True only when the column was decoded from the wire and the
    // arena is still available for zero-copy views. Eager columns
    // built from `[String]` have no arena to vend views from; callers
    // must fall back to `values` in that case.
    var hasArena: Bool { storage.hasArena }

    // Total length of the contiguous UTF-8 arena, in bytes. Useful
    // for bench instrumentation that wants to report byte volume
    // without materialising the strings.
    var arenaByteCount: Int { storage.arenaByteCount }

    init(spec: ClickHouseColumnSpec = .string, values: [String]) {
        self.spec = spec
        self.storage = Storage(eager: values)
    }

    init(spec: ClickHouseColumnSpec, deferredArena arena: [UInt8], offsets: [Int]) {
        self.spec = spec
        self.storage = Storage(deferredArena: arena, offsets: offsets)
    }

    func encode(into buffer: inout ByteBuffer) {
        buffer.writeClickHouseStrings(values)
    }

    static func decode(spec: ClickHouseColumnSpec = .string, rows: Int, from buffer: inout ByteBuffer) throws -> Self {
        var arena: [UInt8] = []
        var offsets: [Int] = []
        try buffer.readClickHouseStringsArena(rows: rows, arena: &arena, offsets: &offsets)
        return .init(spec: spec, deferredArena: arena, offsets: offsets)
    }

    // Build a zero-copy view for the given row. Requires the column
    // to have been wire-decoded (i.e. backed by an arena). Eager
    // columns constructed from `[String]` will trap; the caller is
    // expected to gate access through `hasArena`.
    func stringView(at rowIndex: Int) -> ClickHouseStringView {
        storage.stringView(at: rowIndex)
    }

    // Iterate every row by view, invoking `body` with the view.
    // Avoids per-row Swift `String` allocations entirely when the
    // body never escapes the view. Eager columns trap; callers are
    // expected to gate access through `hasArena`.
    func forEachStringView(_ body: (Int, ClickHouseStringView) -> Void) {
        storage.forEachStringView(body)
    }

    // Build a full-column view backed by the same arena. The
    // returned view owns a shared reference to the arena, so it
    // keeps the bytes alive independently of this column instance.
    func makeColumnView(name: String) -> ClickHouseStringColumnView {
        storage.makeColumnView(name: name)
    }

    final class Storage: @unchecked Sendable {

        private let lock = NIOLock()
        private let source: Source
        private var state: State
        private let arenaHandle: ClickHouseStringArena
        private let arenaOffsets: [Int]

        var rowCount: Int {
            switch source {
            case .eager(let values): return values.count
            case .deferred(_, let offsets): return max(0, offsets.count - 1)
            }
        }

        var hasArena: Bool {
            switch source {
            case .eager: return false
            case .deferred: return true
            }
        }

        var arenaByteCount: Int { arenaHandle.count }

        init(eager values: [String]) {
            self.source = .eager(values)
            self.state = .resolved(values)
            self.arenaHandle = ClickHouseStringArena(bytes: [])
            self.arenaOffsets = []
        }

        init(deferredArena arena: [UInt8], offsets: [Int]) {
            self.source = .deferred(arena: arena, offsets: offsets)
            self.state = .pending
            self.arenaHandle = ClickHouseStringArena(bytes: arena)
            self.arenaOffsets = offsets
        }

        var resolvedValues: [String] {
            lock.withLock { resolveLocked() }
        }

        func stringView(at rowIndex: Int) -> ClickHouseStringView {
            let start = arenaOffsets[rowIndex]
            let end = arenaOffsets[rowIndex + 1]
            return ClickHouseStringView(arena: arenaHandle, byteOffset: start, byteCount: end - start)
        }

        func forEachStringView(_ body: (Int, ClickHouseStringView) -> Void) {
            let count = max(0, arenaOffsets.count - 1)
            for index in 0..<count {
                body(index, stringView(at: index))
            }
        }

        func makeColumnView(name: String) -> ClickHouseStringColumnView {
            ClickHouseStringColumnView(name: name, arena: arenaHandle, offsets: arenaOffsets)
        }

        private func resolveLocked() -> [String] {
            switch state {
            case .resolved(let values): return values
            case .pending:
                let built = Self.buildValues(from: source)
                state = .resolved(built)
                return built
            }
        }

        private static func buildValues(from source: Source) -> [String] {
            switch source {
            case .eager(let values): return values
            case .deferred(let arena, let offsets):
                return materialise(arena: arena, offsets: offsets)
            }
        }

        // Closed-form of the eager / lazy source provided to this
        // storage, captured once at init and held immutably for the
        // lifetime of the column. The eager source carries the
        // caller-provided [String] directly; the deferred source
        // holds the arena bytes and offsets index produced by the
        // wire decoder.
        private enum Source: Sendable {

            case eager([String])
            case deferred(arena: [UInt8], offsets: [Int])

        }

        // Materialisation state. `.pending` means the values have not
        // been computed yet; `.resolved` carries the cached snapshot
        // and short-circuits subsequent reads.
        private enum State: Sendable {

            case pending
            case resolved([String])

        }

        // The arena layout mirrors clickhouse-cpp's `ColumnString::Block`
        // pattern: one contiguous byte buffer plus an offsets index.
        // Materialisation does N `String(decoding:as:)` calls, each one
        // a single malloc + memcpy from the arena. The cost is identical
        // to the eager-decode path that used to live in
        // `readClickHouseStrings`, but the wall-clock cost is now paid
        // only by the caller that asks for `values` — and only once,
        // because the resolver caches the result.
        private static func materialise(arena: [UInt8], offsets: [Int]) -> [String] {
            let count = max(0, offsets.count - 1)
            guard count > 0 else { return [] }
            var result: [String] = []
            result.reserveCapacity(count)
            arena.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for index in 0..<count {
                    let start = offsets[index]
                    let end = offsets[index + 1]
                    let length = end - start
                    if length == 0 {
                        result.append("")
                    } else {
                        let slice = UnsafeRawBufferPointer(start: base.advanced(by: start), count: length)
                        result.append(String(decoding: slice, as: Unicode.UTF8.self))
                    }
                }
            }
            return result
        }

    }

}
