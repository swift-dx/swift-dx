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

import CSQLite

// Holds the aggregator factory; retained into SQLite's user-data for the
// function's lifetime and released by the xDestroy thunk. Sendable because the
// factory closure is the only stored state.
final class SQLiteAggregateBox: Sendable {

    let makeAggregator: @Sendable () -> any SQLiteAggregator

    init(makeAggregator: @escaping @Sendable () -> any SQLiteAggregator) {
        self.makeAggregator = makeAggregator
    }
}

// Wraps one aggregation's existential aggregator so it can be stored as a
// single pointer inside SQLite's per-aggregation context slot. Not Sendable and
// never shared: it lives on one connection thread for one aggregation only.
final class SQLiteAggregatorBox {

    let aggregator: any SQLiteAggregator

    init(_ aggregator: any SQLiteAggregator) {
        self.aggregator = aggregator
    }
}

// Called once per input row. On the first row it creates the aggregator and
// retains it into the per-aggregation slot; later rows recover it unretained.
func dxAggregateStepThunk(_ context: OpaquePointer?, _ argumentCount: Int32, _ arguments: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let context, let userData = sqlite3_user_data(context) else { return }
    stepAggregate(context, userData: userData, argumentCount: argumentCount, arguments: arguments)
}

private func stepAggregate(_ context: OpaquePointer, userData: UnsafeMutableRawPointer, argumentCount: Int32, arguments: UnsafeMutablePointer<OpaquePointer?>?) {
    let factory = Unmanaged<SQLiteAggregateBox>.fromOpaque(userData).takeUnretainedValue()
    guard let slot = sqlite3_aggregate_context(context, Int32(MemoryLayout<UnsafeMutableRawPointer?>.stride)) else {
        sqlite3_result_error_nomem(context)
        return
    }
    let box = stepAggregatorBox(at: slot, factory: factory)
    do {
        try box.aggregator.step(readFunctionArguments(argumentCount, arguments))
    } catch {
        sqlite3_result_error(context, "\(error)", -1)
    }
}

// Called exactly once per allocated aggregation (even on zero rows or a step
// error), so consuming the retained box here balances the step-time retain.
func dxAggregateFinalThunk(_ context: OpaquePointer?) {
    guard let context, let userData = sqlite3_user_data(context) else { return }
    let factory = Unmanaged<SQLiteAggregateBox>.fromOpaque(userData).takeUnretainedValue()
    let box = consumeAggregatorBox(at: context, factory: factory)
    do {
        setFunctionResult(try box.aggregator.finalize(), on: context)
    } catch {
        sqlite3_result_error(context, "\(error)", -1)
    }
}

func dxAggregateDestroyThunk(_ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<SQLiteAggregateBox>.fromOpaque(userData).release()
}

private func stepAggregatorBox(at slot: UnsafeMutableRawPointer, factory: SQLiteAggregateBox) -> SQLiteAggregatorBox {
    let pointerSlot = slot.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let existing = pointerSlot.pointee {
        return Unmanaged<SQLiteAggregatorBox>.fromOpaque(existing).takeUnretainedValue()
    }
    let created = SQLiteAggregatorBox(factory.makeAggregator())
    pointerSlot.pointee = Unmanaged.passRetained(created).toOpaque()
    return created
}

private func consumeAggregatorBox(at context: OpaquePointer, factory: SQLiteAggregateBox) -> SQLiteAggregatorBox {
    guard let slot = sqlite3_aggregate_context(context, 0) else {
        return SQLiteAggregatorBox(factory.makeAggregator())
    }
    let pointerSlot = slot.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let stored = pointerSlot.pointee else {
        return SQLiteAggregatorBox(factory.makeAggregator())
    }
    return Unmanaged<SQLiteAggregatorBox>.fromOpaque(stored).takeRetainedValue()
}
