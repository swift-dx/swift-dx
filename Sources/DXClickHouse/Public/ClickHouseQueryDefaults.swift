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

/// Defaults applied to every public ClickHouseClient operation that
/// accepts a `timeout:` parameter.
///
/// Each operation method exposes a `timeout:` parameter with one of the
/// values below as its default. Callers that want a different value pass
/// it explicitly per call. The defaults are tuned for typical OLAP
/// workloads: short for round-trips (`select`, `scalar`, `execute`,
/// `ping`), longer for batched inserts, and very long for continuous
/// streaming reads.
public enum ClickHouseQueryDefaults {

    /// Default timeout for SELECT-shaped operations: `select`, `scalar`,
    /// `selectAll`, and the bare `execute`. 30 seconds — long enough
    /// for a healthy OLAP scan; short enough that a stuck server does
    /// not deadlock a request handler indefinitely.
    public static let selectTimeout: Duration = .seconds(30)

    /// Default timeout for `insert` calls. 60 seconds; large native
    /// batches take longer to flush server-side than a typical SELECT.
    public static let insertTimeout: Duration = .seconds(60)

    /// Default timeout for `ping`. 5 seconds; ping is a single
    /// round-trip and should never need longer on a healthy network.
    public static let pingTimeout: Duration = .seconds(5)

    /// Default timeout for `stream` (continuous reads driven by a
    /// `DXMessageHandler`). 5 minutes; streams are expected to run for
    /// long durations, but an unbounded read with no timeout would
    /// deadlock the caller forever on a stuck server.
    public static let streamTimeout: Duration = .seconds(300)
}
