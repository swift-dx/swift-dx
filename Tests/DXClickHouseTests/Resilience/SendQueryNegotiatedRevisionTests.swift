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

@testable import DXClickHouse
import Foundation
import Testing

// The no-argument `sendQuery(_:)` shorthand on the connection must build
// its Query packet at the revision negotiated with the server, exactly
// like the full-surface overload. Routing it through the fixed client
// revision instead emits the newer revision-gated clientInfo fields to a
// server that does not expect them, desyncing the packet stream — the
// same defect class fixed for the full-surface path, but on the public
// AsyncClickHouseConnection shorthand and the benchmark path.
@Suite("the no-argument sendQuery builds at the negotiated revision")
struct SendQueryNegotiatedRevisionTests {

    @Test("sendQuery(_:) honors the negotiated server revision, not the fixed client revision", .timeLimit(.minutes(1)))
    func shorthandUsesNegotiatedRevision() async throws {
        // Pick a server revision below the client's own so the negotiated
        // value (their minimum) differs from the fixed client revision.
        let negotiated: UInt64 = 54_460
        #expect(negotiated < ClickHouseQueryBuilder.revision)

        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(revision: negotiated),
            script: [.drainRequest]
        )
        defer { server.stop() }

        let connection = try await AsyncClickHouseConnection(host: "127.0.0.1", port: server.port)
        try await connection.sendQuery("SELECT 1")
        await connection.close()
        server.finished.wait()

        let request = try #require(server.capturedRequests.first)
        let expectedAtNegotiated = try ClickHouseQueryBuilder.buildQuery(
            "SELECT 1",
            queryID: "",
            settings: .empty,
            parameters: .empty,
            revision: negotiated
        )
        #expect(request == expectedAtNegotiated)
    }
}
