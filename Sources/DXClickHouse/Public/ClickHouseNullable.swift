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

// Per-row null marker for ClickHouse `Nullable(T)` columns. Each
// element in a nullable column carries either `.present(value)` or
// `.absent`, mirroring the per-row null mask that the ClickHouse
// native wire format transmits alongside the inner column. This
// replaces a per-row `T?` with a typed sum so SwiftDX's no-Optionals
// rule holds end-to-end across the public surface.
public enum ClickHouseNullable<Value: Sendable & Hashable>: Sendable, Hashable {

    case present(Value)
    case absent

}

extension ClickHouseNullable {

    // Bridge into Swift's standard Optional for ergonomics at the
    // edges of the system (test construction, Foundation `Codable`
    // interop, callers that already hold an `Optional<T>`). The
    // accessor returns `Value?` so reaching for `nil` reads
    // naturally at the call site even though the storage form is a
    // named enum case.
    public var value: Value? {
        switch self {
        case .present(let unwrapped): return unwrapped
        case .absent: return nil
        }
    }

    public init(_ optional: Value?) {
        self = optional.map { .present($0) } ?? .absent
    }

}

// `nil` as a literal in array construction (`[.present(1), nil]`)
// reads as the absent marker without round-tripping through an
// Optional value. This is purely an expressibility convenience —
// the type still has no Optional storage, and a value-producing
// `nil` would still need to go through the typed enum cases.
extension ClickHouseNullable: ExpressibleByNilLiteral {

    public init(nilLiteral: ()) {
        self = .absent
    }

}

// Literal conformances mirror Value's own literal conformances so
// that a `[ClickHouseNullable<Int32>]` array can be written as
// `[10, nil, -5]` rather than `[.present(10), .absent,
// .present(-5)]`. Without these the test-construction ergonomics
// regress sharply and consumers writing typed payloads suffer the
// same noise. Each conformance only activates when the wrapped
// `Value` type supports the same literal, so the conformance
// surface stays accurate.

extension ClickHouseNullable: ExpressibleByIntegerLiteral where Value: ExpressibleByIntegerLiteral {

    public init(integerLiteral value: Value.IntegerLiteralType) {
        self = .present(Value(integerLiteral: value))
    }

}

extension ClickHouseNullable: ExpressibleByFloatLiteral where Value: ExpressibleByFloatLiteral {

    public init(floatLiteral value: Value.FloatLiteralType) {
        self = .present(Value(floatLiteral: value))
    }

}

extension ClickHouseNullable: ExpressibleByBooleanLiteral where Value: ExpressibleByBooleanLiteral {

    public init(booleanLiteral value: Value.BooleanLiteralType) {
        self = .present(Value(booleanLiteral: value))
    }

}

extension ClickHouseNullable: ExpressibleByStringLiteral where Value: ExpressibleByStringLiteral {

    public init(stringLiteral value: Value.StringLiteralType) {
        self = .present(Value(stringLiteral: value))
    }

}

extension ClickHouseNullable: ExpressibleByExtendedGraphemeClusterLiteral where Value: ExpressibleByExtendedGraphemeClusterLiteral {

    public init(extendedGraphemeClusterLiteral value: Value.ExtendedGraphemeClusterLiteralType) {
        self = .present(Value(extendedGraphemeClusterLiteral: value))
    }

}

extension ClickHouseNullable: ExpressibleByUnicodeScalarLiteral where Value: ExpressibleByUnicodeScalarLiteral {

    public init(unicodeScalarLiteral value: Value.UnicodeScalarLiteralType) {
        self = .present(Value(unicodeScalarLiteral: value))
    }

}
