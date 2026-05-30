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

    // Compression methods the Swift client is willing to send on the
    // wire. The full set of methods the wire format can carry
    // (including ZSTD, which the server may emit) lives on the
    // internal `ClickHouseCompressionMethod` enum. Splitting the two
    // keeps the public configuration surface honest: a value here is
    // a value the encoder will actually produce.
    public enum OutboundCompression: Sendable, Equatable {

        case uncompressed
        case lz4

    }

}

extension ClickHouseClient.OutboundCompression {

    var wireMethod: ClickHouseCompressionMethod {
        switch self {
        case .uncompressed:
            return .uncompressed
        case .lz4:
            return .lz4
        }
    }

}
