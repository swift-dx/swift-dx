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

import Testing
@testable import DXPostgres

@Suite struct ConnectFailureTests {

    @Test(.timeLimit(.minutes(1)))
    func connectToARefusedPortThrowsConnectFailed() {
        do {
            _ = try BlockingPostgresConnection.connect(host: "127.0.0.1", port: 1, username: "app", password: "app", database: "app", applicationName: "test", searchPath: .serverDefault)
            Issue.record("expected a connection to a refused port to throw")
        } catch let error as PostgresError {
            guard case .connectFailed = error else {
                Issue.record("expected connectFailed, got \(error)")
                return
            }
        }
    }
}
