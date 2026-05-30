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
import NIOCore

extension ClickHouseClient {

    // Streams typed `Decodable` rows by decoding the SELECT's columnar
    // Data blocks into a per-row JSON object and feeding each one
    // through the supplied `JSONDecoder`.
    //
    // The native protocol always returns columnar Data blocks regardless
    // of any `FORMAT` clause in the SQL — `decodedRows` does not append
    // one. Callers that pass `FORMAT JSONEachRow` themselves get the same
    // columnar bytes back, so the wire path is the same. Encoding
    // conventions live on `ClickHouseRowJSONEncoder`.
    public func decodedRows<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        decoder: JSONDecoder = JSONDecoder()
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await block in self.select(sql, settings: settings, parameters: parameters) {
                        // The first Data block from a SELECT carries the
                        // schema with rowCount == 0; only blocks with
                        // rows produce decodable values.
                        guard block.rowCount > 0 else { continue }
                        for rowIndex in 0..<block.rowCount {
                            let payload = try ClickHouseRowJSONEncoder.encode(block: block, rowIndex: rowIndex)
                            let row = try decoder.decode(T.self, from: payload)
                            // Honor consumer abandonment mid-block. Without
                            // this, a 100k-row block keeps encoding and
                            // decoding rows after the consumer has stopped
                            // iterating, wasting CPU on values nobody reads.
                            if case .terminated = continuation.yield(row) {
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func collectDecodedRows<T: Decodable & Sendable>(
        _ sql: String,
        as type: T.Type,
        settings: [ClickHouseQuerySetting] = [],
        parameters: [ClickHouseQueryParameter] = [],
        decoder: JSONDecoder = JSONDecoder()
    ) async throws(ClickHouseError) -> [T] {
        try await ClickHouseError.bridge {
            var collected: [T] = []
            for try await row in decodedRows(sql, as: type, settings: settings, parameters: parameters, decoder: decoder) {
                collected.append(row)
            }
            return collected
        }
    }

}
