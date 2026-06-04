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

// Parses the text rendering of `inet`/`cidr` into a PostgresInet. IPv4
// (`a.b.c.d[/n]`) is parsed here; IPv6 text is read through the exact binary path
// of a parameterized query, so IPv6 text decoding reports a clear error rather
// than a partial parse. A missing prefix defaults to the host width (/32).
enum PostgresInetText {

    static func parse(_ text: String) throws(PostgresError) -> PostgresInet {
        let (host, prefix) = splitPrefix(text)
        guard !host.contains(":") else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInet", reason: "IPv6 text decoding is unsupported; read inet through a parameterized query (binary)")
        }
        return PostgresInet(isIPv6: false, address: try ipv4Bytes(host), prefixLength: prefix, isCIDR: false)
    }

    // An IPv4 address with no `/n` defaults to the host width, /32. Only IPv4 is
    // parsed from text, so the default never applies to an IPv6 value.
    private static func splitPrefix(_ text: String) -> (host: Substring, prefix: UInt8) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let prefix = UInt8(parts[1]) else { return (Substring(text), 32) }
        return (parts[0], prefix)
    }

    private static func ipv4Bytes(_ host: Substring) throws(PostgresError) -> [UInt8] {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInet", reason: "malformed IPv4 address '\(host)'")
        }
        var bytes: [UInt8] = []
        for part in parts {
            bytes.append(try octet(part))
        }
        return bytes
    }

    private static func octet(_ text: Substring) throws(PostgresError) -> UInt8 {
        guard let value = UInt8(text) else {
            throw PostgresError.typeDecodingFailed(type: "PostgresInet", reason: "IPv4 octet out of range '\(text)'")
        }
        return value
    }
}
