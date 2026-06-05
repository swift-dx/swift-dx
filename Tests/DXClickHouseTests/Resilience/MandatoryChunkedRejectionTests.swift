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
import Testing

// From protocol revision 54470 the server advertises a chunked-framing
// preference per direction. This client only speaks the unframed
// ("notchunked") transport and reads blocks directly off the socket. A
// server configured to MANDATE "chunked" would wrap every block in a
// length-prefixed chunk frame, which this client would misread as block
// bytes - silently desyncing the very first result. The handshake reads the
// preference but used to discard it; it must reject a mandatory-chunked peer
// up front with a clear error instead.
@Suite("a server that mandates chunked framing is rejected at the handshake")
struct MandatoryChunkedRejectionTests {

    @Test("a mandatory-chunked ServerHello fails the connection with a typed error", .timeLimit(.minutes(1)))
    func rejectsMandatoryChunkedServer() throws {
        let server = FakeClickHouseServer()
        server.run(
            serverHello: FakeClickHouseServer.serverHello(
                revision: ClickHouseQueryBuilder.revision,
                chunkedSend: "chunked"
            ),
            script: []
        )

        var stage = "none"
        var rejected = false
        do {
            let connection = try ClickHouseConnection(host: "127.0.0.1", port: server.port)
            connection.close()
        } catch {
            if case .protocolError(let parsed, let message) = error {
                stage = parsed
                rejected = message.contains("chunked protocol framing")
            }
        }
        server.finished.wait()

        #expect(stage == "hello")
        #expect(rejected)
    }
}
