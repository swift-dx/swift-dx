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

extension ClickHouseClient {

    // Block source for streaming INSERTs. Returning `.endOfStream`
    // terminates the stream cleanly; returning `.batch([])` is a
    // legal "skip this tick" signal that does not end the stream.
    public typealias BlockProvider = @Sendable () async throws -> ClickHouseColumnBatchOutcome

    // Streaming INSERT for ETL pipelines and other lazy data sources.
    // The provider closure is called repeatedly to fetch the next block;
    // returning `.endOfStream` ends the stream. Compared to
    // `insert(into:blocks:)`, this never materializes the full block
    // array — peak memory is one block at a time, regardless of how
    // many blocks are sent.
    //
    // Block structure (column names + specs) is validated as each block
    // arrives. A mismatch on block N throws and tears down the connection
    // (the partial INSERT is discarded server-side).
    public func insert(
        into table: String,
        blockProvider: BlockProvider,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        onProgress: @escaping @Sendable (ClickHouseProgress) -> Void = { _ in }
    ) async throws(ClickHouseError) {
        try await ClickHouseError.bridge {
            // Peek the first batch BEFORE acquiring a pool connection. If
            // the provider has nothing to send, skip the wire round-trip
            // entirely — symmetric with `insert(into:columns: [])` and
            // `insert(into:blocks: [])` short-circuits. ETL pipelines that
            // hand the streaming API a generator with no upstream data
            // (this tick) shouldn't pay for a connection acquisition, a
            // Query+schema+terminator round-trip, and the EndOfStream wait
            // just to issue a server-side zero-row INSERT.
            let firstColumns: [ClickHouseColumnEntry]
            switch try await blockProvider() {
            case .batch(let columns):
                firstColumns = columns
            case .endOfStream:
                return
            }

            let shapeTracker = ClickHouseStreamingInsertShape()
            let firstHolder = FirstBlockHolder(firstColumns)
            // Explicit column list keyed off the first batch — all batches
            // share the same shape (enforced by `shapeTracker`), so the
            // names from the first batch describe every subsequent block.
            // See `ClickHouseClient+Insert.swift` for the rationale: a bare
            // `INSERT INTO t FORMAT Native` makes the server announce every
            // destination column in its sample block, which then fails the
            // count check when the caller wrote only a subset.
            let columnList = Self.makeColumnListSQL(firstColumns)
            try await pool.withConnection { connection in
                try await connection.insertBlockStream(
                    "INSERT INTO \(table) \(columnList) FORMAT Native",
                    nextBlock: { () async throws -> ClickHouseBlockCursorOutcome in
                        // Drain the peeked first batch, then resume the
                        // user's provider for subsequent batches. The
                        // closure is called serially by the connection's
                        // INSERT loop, so the holder's take() doesn't
                        // need additional locking — same contract as
                        // `ClickHouseStreamingInsertShape`.
                        let columns: [ClickHouseColumnEntry]
                        switch firstHolder.take() {
                        case .pending(let first):
                            columns = first
                        case .alreadyTaken:
                            switch try await blockProvider() {
                            case .batch(let next): columns = next
                            case .endOfStream: return .endOfStream
                            }
                        }
                        let block = try Self.makeBlock(from: columns)
                        try shapeTracker.recordAndValidate(block: block)
                        return .block(block)
                    },
                    settings: settings,
                    parameters: parameters,
                    onProgress: onProgress
                )
            }
        }
    }

}

// Take-result for the streaming-insert peeked first batch.
private enum FirstBlockTakeResult {

    case pending([ClickHouseColumnEntry])
    case alreadyTaken

}

// One-shot holder for the streaming-insert peeked first batch. The
// class wrapper provides mutable-reference semantics across the
// `nextBlock` closure's invocations; access is serial by the INSERT
// loop's contract (no concurrent calls per connection), matching the
// existing `ClickHouseStreamingInsertShape` pattern.
private final class FirstBlockHolder: @unchecked Sendable {

    private var state: FirstBlockTakeResult

    init(_ pending: [ClickHouseColumnEntry]) {
        self.state = .pending(pending)
    }

    func take() -> FirstBlockTakeResult {
        let value = state
        state = .alreadyTaken
        return value
    }

}
