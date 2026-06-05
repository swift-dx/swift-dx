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

// A type decoded through the fused fast path: the result block is parsed into
// direct byte views (ClickHouseRawBlock) and the rows are built in a single
// pass straight from those views, with no intermediate typed-column arrays.
// This is the lowest-overhead read DXClickHouse offers, matching what a
// hand-written columnar client does. Conform by hand, or apply the
// `@ClickHouseRow` macro to generate both requirements.
public protocol ClickHouseFusedDecodable {

    static var clickHouseColumnNames: [String] { get }

    static func decodeFused(_ block: ClickHouseRawBlock) throws(ClickHouseError) -> [Self]
}
