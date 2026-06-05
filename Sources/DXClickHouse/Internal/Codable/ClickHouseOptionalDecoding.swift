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

// Bridges an explicitly-requested Optional decode target into the columnar
// keyed container's existing decodeIfPresent path. The generic
// decode<T>(_:forKey:) is invoked when a caller decodes an Optional value
// directly — for example the nullable-scalar path, where
// ScalarRowWrapper<Int32?> runs `container.decode(Optional<Int32>.self)`.
// Every Optional whose Wrapped is Decodable conforms here, so the container
// can detect it at runtime and route to decodeIfPresent rather than
// rejecting Optional as an unsupported decode target. The boxed `Any` holds
// the resolved `Wrapped?`, which the container force-casts back to `T`.
protocol ClickHouseOptionalDecoding {

    static func clickHouseDecodeNullable<Key: CodingKey>(
        from container: ClickHouseColumnarKeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Any
}

extension Optional: ClickHouseOptionalDecoding where Wrapped: Decodable {

    static func clickHouseDecodeNullable<Key: CodingKey>(
        from container: ClickHouseColumnarKeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Any {
        // decodeIfPresent returns the resolved Wrapped value or its absence;
        // boxing the result as Any erases the Optional at the source level
        // (no Optional type is named here) while preserving the value the
        // container force-casts back to the requested Optional target.
        try container.decodeIfPresent(Wrapped.self, forKey: key) as Any
    }
}
