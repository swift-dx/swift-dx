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

let rev = ClickHouseQueryBuilder.revision
let hello = ClickHouseQueryBuilder.buildHello(database: "default", user: "default", password: "dxtest")
let addendum = ClickHouseQueryBuilder.buildAddendum(serverRevision: rev)
let query = ClickHouseQueryBuilder.buildQuery("SELECT id, name, value FROM dx_swiftbench")
let insertQuery = ClickHouseQueryBuilder.buildQuery("INSERT INTO dx_swiftbench (id, name, value) FORMAT Native")
func emit(_ label: String, _ bytes: [UInt8]) {
    print("\(label)=\(bytes.map { String($0) }.joined(separator: ","))")
}
print("REVISION=\(rev)")
emit("HELLO", hello)
emit("ADDENDUM", addendum)
emit("QUERY", query)
emit("INSERTQUERY", insertQuery)
