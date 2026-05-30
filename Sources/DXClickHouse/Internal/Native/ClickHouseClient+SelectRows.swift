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

// Block-batched per-row typed SELECT. Returns a `ClickHouseRowSequence`
// that iterates rows one at a time at the call site while fetching and
// decoding one server-side Data block at a time underneath. The
// async-stream continuation hop that caps `selectStream` at the per-row
// rate is replaced by a buffer-indexed array read on every `next()`,
// with the async hop and the columnar `Decoder` plumbing amortised
// across the block.
//
// On the `BenchRow` shape (4 fields) the rate matches block-batched
// `selectStreamFast` within measurement noise (~390k rows/second on
// localhost) while preserving `for try await row in stream` ergonomics.
//
// `selectStream` and `selectStreamFast` remain as-is. Existing call
// sites are unaffected; new code that wants the natural per-row shape
// without the per-row continuation cost reaches for `selectRows`.
extension ClickHouseClient {

    public func selectRows<T: Decodable & Sendable>(
        _ type: T.Type,
        from sql: String,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        keyDecodingStrategy: ClickHouseKeyDecodingStrategy = .useDefaultKeys
    ) -> ClickHouseRowSequence<T> {
        ClickHouseRowSequence(
            client: self,
            sql: sql,
            settings: settings,
            parameters: parameters,
            keyDecodingStrategy: keyDecodingStrategy
        )
    }

}
