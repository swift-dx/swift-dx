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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Typed wrapper over the 16-byte raw value that ClickHouse uses for
// `IPv6` columns. Round-trips through the wire codec verbatim — the
// rawValue *is* the on-the-wire byte sequence (RFC 4291 representation).
//
// String parsing/formatting uses POSIX `inet_pton`/`inet_ntop`, which
// covers the full IPv6 grammar (`::` zero-compression, IPv4-mapped
// addresses, etc.) without re-implementing 200 lines of parser logic.
public struct ClickHouseIPv6Address: Sendable, Equatable, Hashable {

    public static let byteLength: Int = 16

    public let rawValue: Data

    // Construct from raw 16-byte value as it appears on the wire.
    // Returns `nil` for any input that isn't exactly 16 bytes — IPv6
    // is a fixed-width address family.
    public init?(_ rawValue: Data) {
        guard rawValue.count == Self.byteLength else { return nil }
        self.rawValue = rawValue
    }

    // Parse the canonical or compressed string forms:
    //   2001:0db8:0000:0000:0000:0000:0000:0001
    //   2001:db8::1                              (zero-compression)
    //   ::1                                      (loopback)
    //   ::ffff:192.0.2.1                         (IPv4-mapped)
    public init?(string: String) {
        var address = in6_addr()
        let result = string.withCString { cstr in
            inet_pton(AF_INET6, cstr, &address)
        }
        guard result == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == Self.byteLength else { return nil }
        self.rawValue = Data(bytes)
    }

    // Canonical string form: lowercase hex, no leading zeros per group,
    // longest run of zero groups compressed with `::`. Throws only if
    // the underlying bytes don't form a valid `in6_addr` layout —
    // unreachable for values constructed through this type, defensive
    // against external Data sources mutating the rawValue.
    public func stringValue() throws(ClickHouseError) -> String {
        var address = in6_addr()
        rawValue.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address) { destination in
                destination.copyMemory(from: source)
            }
        }
        var buffer = [UInt8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let success = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Bool in
            guard let baseAddress = bufferPointer.baseAddress else { return false }
            return baseAddress.withMemoryRebound(to: CChar.self, capacity: Int(INET6_ADDRSTRLEN)) { cPointer in
                inet_ntop(AF_INET6, &address, cPointer, socklen_t(INET6_ADDRSTRLEN)) != nil
            }
        }
        guard success else {
            throw ClickHouseError.malformedIPv6Address
        }
        let nullByte = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<nullByte], as: UTF8.self)
    }

    public static let zero: ClickHouseIPv6Address = ClickHouseIPv6Address(unchecked: Data(repeating: 0, count: byteLength))

    // ::1 IPv6 loopback (15 zero bytes + 0x01)
    public static let loopback: ClickHouseIPv6Address = {
        var bytes = Data(repeating: 0, count: byteLength)
        bytes[byteLength - 1] = 1
        return ClickHouseIPv6Address(unchecked: bytes)
    }()

    // Internal constructor for callers that have already proven the
    // 16-byte invariant statically (compile-time literals like `.zero`
    // and `.loopback`). Bypasses the Optional wrapper so call sites
    // don't need force-unwraps.
    private init(unchecked rawValue: Data) {
        self.rawValue = rawValue
    }

}
