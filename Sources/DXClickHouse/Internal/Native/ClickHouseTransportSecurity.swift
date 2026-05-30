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

    // Transport security for ClickHouse connections. `.plaintext` is
    // an unencrypted TCP connection; `.tls(...)` requires a successful
    // TLS handshake before the ClickHouse protocol begins.
    public enum TransportSecurity: Sendable {

        case plaintext
        case tls(TLSOptions)

    }

}
