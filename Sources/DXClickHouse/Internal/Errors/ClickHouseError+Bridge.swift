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
import NIOCore

extension ClickHouseError {

    // Runs an `async throws` body whose error type is `any Error` and
    // re-throws every caught error as a typed `ClickHouseError`. Most
    // operations already throw `ClickHouseError` internally, in which
    // case the rethrow is a direct typed pass-through. `DecodingError`
    // and `EncodingError` thrown by the Codable runtime are converted
    // to structured `codableDecodingFailure` / `codableEncodingFailure`
    // cases. Any other error type is wrapped as
    // `codableDecodingFailure` with `kind: .unknown` so the typed-throws
    // contract holds for every public surface.
    static func bridge<Value>(
        _ body: () async throws -> Value
    ) async throws(ClickHouseError) -> Value {
        do {
            return try await body()
        } catch {
            throw Self.translate(error)
        }
    }

    static func bridgeSync<Value>(
        _ body: () throws -> Value
    ) throws(ClickHouseError) -> Value {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    static func translate(_ error: any Error) -> ClickHouseError {
        switch translateKnownError(error) {
        case .recognized(let known): return known
        case .unrecognized: return wrapUnknownError(error)
        }
    }

    private enum TranslationOutcome {

        case recognized(ClickHouseError)
        case unrecognized

    }

    private static func translateKnownError(_ error: any Error) -> TranslationOutcome {
        if let typed = error as? ClickHouseError { return .recognized(typed) }
        if error is CancellationError { return .recognized(.cancelled) }
        return translateNIOOrCodableError(error)
    }

    private static func translateNIOOrCodableError(_ error: any Error) -> TranslationOutcome {
        if let channel = error as? ChannelError, channelErrorIsClose(channel) {
            return .recognized(.unexpectedConnectionClose)
        }
        return translateCodableError(error)
    }

    private static func translateCodableError(_ error: any Error) -> TranslationOutcome {
        if let decoding = error as? DecodingError { return .recognized(.from(decodingError: decoding)) }
        if let encoding = error as? EncodingError { return .recognized(.from(encodingError: encoding)) }
        return .unrecognized
    }

    private static func channelErrorIsClose(_ channel: ChannelError) -> Bool {
        channel == .ioOnClosedChannel || channel == .alreadyClosed
    }

    private static func wrapUnknownError(_ error: any Error) -> ClickHouseError {
        .codableDecodingFailure(
            kind: .unknown,
            typeName: String(reflecting: type(of: error)),
            codingPath: "",
            debugDescription: String(reflecting: error)
        )
    }

    static func from(decodingError: DecodingError) -> ClickHouseError {
        switch decodingError {
        case .typeMismatch(let type, let context):
            return .codableDecodingFailure(
                kind: .typeMismatch,
                typeName: String(reflecting: type),
                codingPath: Self.format(codingPath: context.codingPath),
                debugDescription: context.debugDescription
            )
        case .valueNotFound(let type, let context):
            return .codableDecodingFailure(
                kind: .valueNotFound,
                typeName: String(reflecting: type),
                codingPath: Self.format(codingPath: context.codingPath),
                debugDescription: context.debugDescription
            )
        case .keyNotFound(let key, let context):
            return .codableDecodingFailure(
                kind: .keyNotFound,
                typeName: key.stringValue,
                codingPath: Self.format(codingPath: context.codingPath),
                debugDescription: context.debugDescription
            )
        case .dataCorrupted(let context):
            return .codableDecodingFailure(
                kind: .dataCorrupted,
                typeName: "",
                codingPath: Self.format(codingPath: context.codingPath),
                debugDescription: context.debugDescription
            )
        @unknown default:
            return .codableDecodingFailure(
                kind: .unknown,
                typeName: "",
                codingPath: "",
                debugDescription: String(reflecting: decodingError)
            )
        }
    }

    static func from(encodingError: EncodingError) -> ClickHouseError {
        switch encodingError {
        case .invalidValue(let value, let context):
            return .codableEncodingFailure(
                kind: .invalidValue,
                typeName: String(reflecting: type(of: value)),
                codingPath: Self.format(codingPath: context.codingPath),
                debugDescription: context.debugDescription
            )
        @unknown default:
            return .codableEncodingFailure(
                kind: .unknown,
                typeName: "",
                codingPath: "",
                debugDescription: String(reflecting: encodingError)
            )
        }
    }

    private static func format(codingPath: [any CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }

}
