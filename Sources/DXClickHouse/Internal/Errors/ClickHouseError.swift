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

public enum ClickHouseError: Error, Sendable, Equatable, CustomStringConvertible {

    case truncatedBuffer(needed: Int, available: Int)
    case uvarintOverflow
    case uvarintIncomplete
    case stringLengthExceedsBuffer(declared: UInt64, available: Int)
    case stringLengthExceedsLimit(declared: UInt64, limit: Int)
    case invalidUTF8
    case invalidBoolean(rawValue: UInt8)
    case fixedStringLengthMismatch(expected: Int, actual: Int)
    case invalidFixedStringLength(Int)
    case nonMonotonicArrayOffsets(at: Int, value: UInt64, previous: UInt64)
    case arrayOffsetExceedsInt(UInt64)
    case nullableInnerRowCountMismatch(expected: Int, actual: Int)
    case tupleElementCountMismatch(expected: Int, actual: Int)
    case tupleInnerRowCountMismatch(elementIndex: Int, expected: Int, actual: Int)
    case unknownTypeName(String)
    case malformedTypeName(at: Int, message: String)
    case typeNameNestingTooDeep(maxDepth: Int)
    case unknownClientPacketType(rawValue: UInt64)
    case unknownServerPacketType(rawValue: UInt64)
    case exceptionNestingTooDeep(maxDepth: Int)
    case unknownBlockInfoField(UInt64)
    case blockColumnCountExceedsInt(UInt64)
    case blockRowCountExceedsInt(UInt64)
    case blockColumnRowCountMismatch(columnIndex: Int, expected: Int, actual: Int)
    case unimplementedServerPacket(packetName: String)
    case unknownClientInfoQueryKind(rawValue: UInt8)
    case unknownClientInfoInterface(rawValue: UInt8)
    case unimplementedTraceContext
    case unknownQueryProcessingStage(rawValue: UInt64)
    case multiBlockStructureMismatch(blockIndex: Int, message: String)
    case unexpectedHandshakeResponse(receivedPacketName: String)
    case unexpectedConnectionClose
    case handshakeRejected(serverException: ServerException)
    case unexpectedPacketDuringQuery(receivedPacketName: String)
    case poolExhausted(maxConnections: Int)
    case poolWaitTimeout(timeoutNanoseconds: Int64, maxConnections: Int)
    case poolShutdown
    case invalidRetryAttempts(Int)
    case invalidConfigurationURL(reason: String)
    case poolHasNoEndpoints
    case blockHasNoColumns
    case allPoolEndpointsFailed(lastError: String)
    case serverException(ServerException)
    case dateValueOutOfRange(seconds: Double, lowerBound: Double, upperBound: Double)
    case invalidDateTime64Precision(Int)
    case invalidDecimalScale(scale: Int, maxScale: Int)
    case lz4MalformedBlock(String)
    case lz4DecompressedSizeMismatch(expected: Int, actual: Int)
    case unexpectedPingResponse(receivedKind: String)
    case compressionFrameTruncated(needed: Int, available: Int)
    case compressionFrameSizeOutOfRange(field: String, value: Int, limit: Int)
    case compressionFrameChecksumMismatch(expectedLow: UInt64, expectedHigh: UInt64, actualLow: UInt64, actualHigh: UInt64)
    case compressionFrameUnknownMethod(rawValue: UInt8)
    case compressionFrameMethodUnsupported(methodRawValue: UInt8, methodName: String)
    case compressionFrameNonePayloadSizeMismatch(expected: Int, actual: Int)
    case unsupportedSelectColumnType(typeName: String)
    case scalarColumnTypeMismatch(actualTypeName: String, expectedKind: String)
    case scalarQueryReturnedZeroRows
    case unknownSerializationKind(rawValue: UInt8)
    case sparseOffsetExceedsRowCount(offset: Int, rows: Int)
    case sparseSerializationOnUnsupportedSpec(typeName: String)
    case sparseScatterTypeMismatch(spec: ClickHouseColumnSpec)
    case unsupportedJSONColumnType(typeName: String)
    case rowIndexOutOfRange(rowIndex: Int, rowCount: Int)
    case handshakeTimedOut(timeoutNanoseconds: Int64)
    case sparseRowCountExceedsLimit(rows: Int, limit: Int)
    case lowCardinalityDictionaryIndexOutOfRange(index: Int, dictionarySize: Int)
    case lowCardinalityInvalidKeyType(rawValue: UInt8)
    case dateTime64TickToNanosecondsOverflow(ticks: Int64, precision: Int)
    case emptyQueryParameterName
    case emptyQuerySettingName
    case internalColumnTypeCastFailure(typeName: String, expectedType: String)
    case rowEncoderUnsupportedType(swiftTypeDescription: String, columnName: String, message: String)
    case rowEncoderColumnTypeMismatch(columnName: String, firstSeen: String, conflictingType: String, atRowIndex: Int)
    case rowEncoderRowMissingColumns(missingColumns: [String], rowIndex: Int)
    case rowDecoderMismatchedColumnRowCounts(columnName: String, expected: Int, actual: Int)
    case rowDecoderUnsupportedColumnValueShape(columnName: String, valueDescription: String)
    case nonFiniteFloatInJSONOutput(textualValue: String, row: Int)
    case insertSampleBlockMissing
    case insertColumnCountMismatch(client: Int, server: Int)
    case insertColumnTypeUnpromotable(column: String, from: ClickHouseColumnSpec, to: ClickHouseColumnSpec)
    case insertEnumUnknownLabel(column: String, label: String, allowedLabels: [String])
    case codableDecodingFailure(kind: CodableFailureKind, typeName: String, codingPath: String, debugDescription: String)
    case codableEncodingFailure(kind: CodableFailureKind, typeName: String, codingPath: String, debugDescription: String)
    case cancelled
    case malformedIPv6Address

    public enum CodableFailureKind: String, Sendable, Equatable {

        case typeMismatch
        case valueNotFound
        case keyNotFound
        case dataCorrupted
        case invalidValue
        case unknown
    }

    public struct ServerException: Sendable, Equatable {

        public let code: Int32
        public let name: String
        public let message: String
        public let stackTrace: String
        public let nestedMessages: [String]

        public init(code: Int32, name: String, message: String, stackTrace: String, nestedMessages: [String]) {
            self.code = code
            self.name = name
            self.message = message
            self.stackTrace = stackTrace
            self.nestedMessages = nestedMessages
        }

    }

    public var description: String { Self.format(self) }

    private static func format(_ value: ClickHouseError) -> String {
        let mirror = Mirror(reflecting: value)
        guard let child = mirror.children.first else {
            return "ClickHouseError.\(Self.caseLabel(value))"
        }
        let label = child.label ?? Self.caseLabel(value)
        let valueMirror = Mirror(reflecting: child.value)
        let payload: String
        if valueMirror.displayStyle == .tuple {
            payload = valueMirror.children
                .map { item in
                    if let l = item.label, !l.hasPrefix(".") {
                        return "\(l): \(String(reflecting: item.value))"
                    }
                    return String(reflecting: item.value)
                }
                .joined(separator: ", ")
        } else {
            payload = String(reflecting: child.value)
        }
        return "ClickHouseError.\(label)(\(payload))"
    }

    private static func caseLabel(_ value: ClickHouseError) -> String {
        switch value {
        case .truncatedBuffer: return "truncatedBuffer"
        case .uvarintOverflow: return "uvarintOverflow"
        case .uvarintIncomplete: return "uvarintIncomplete"
        case .stringLengthExceedsBuffer: return "stringLengthExceedsBuffer"
        case .stringLengthExceedsLimit: return "stringLengthExceedsLimit"
        case .invalidUTF8: return "invalidUTF8"
        case .invalidBoolean: return "invalidBoolean"
        case .fixedStringLengthMismatch: return "fixedStringLengthMismatch"
        case .invalidFixedStringLength: return "invalidFixedStringLength"
        case .nonMonotonicArrayOffsets: return "nonMonotonicArrayOffsets"
        case .arrayOffsetExceedsInt: return "arrayOffsetExceedsInt"
        case .nullableInnerRowCountMismatch: return "nullableInnerRowCountMismatch"
        case .tupleElementCountMismatch: return "tupleElementCountMismatch"
        case .tupleInnerRowCountMismatch: return "tupleInnerRowCountMismatch"
        case .unknownTypeName: return "unknownTypeName"
        case .malformedTypeName: return "malformedTypeName"
        case .typeNameNestingTooDeep: return "typeNameNestingTooDeep"
        case .unknownClientPacketType: return "unknownClientPacketType"
        case .unknownServerPacketType: return "unknownServerPacketType"
        case .exceptionNestingTooDeep: return "exceptionNestingTooDeep"
        case .unknownBlockInfoField: return "unknownBlockInfoField"
        case .blockColumnCountExceedsInt: return "blockColumnCountExceedsInt"
        case .blockRowCountExceedsInt: return "blockRowCountExceedsInt"
        case .blockColumnRowCountMismatch: return "blockColumnRowCountMismatch"
        case .unimplementedServerPacket: return "unimplementedServerPacket"
        case .unknownClientInfoQueryKind: return "unknownClientInfoQueryKind"
        case .unknownClientInfoInterface: return "unknownClientInfoInterface"
        case .unimplementedTraceContext: return "unimplementedTraceContext"
        case .unknownQueryProcessingStage: return "unknownQueryProcessingStage"
        case .multiBlockStructureMismatch: return "multiBlockStructureMismatch"
        case .unexpectedHandshakeResponse: return "unexpectedHandshakeResponse"
        case .unexpectedConnectionClose: return "unexpectedConnectionClose"
        case .handshakeRejected: return "handshakeRejected"
        case .unexpectedPacketDuringQuery: return "unexpectedPacketDuringQuery"
        case .poolExhausted: return "poolExhausted"
        case .poolWaitTimeout: return "poolWaitTimeout"
        case .poolShutdown: return "poolShutdown"
        case .invalidRetryAttempts: return "invalidRetryAttempts"
        case .invalidConfigurationURL: return "invalidConfigurationURL"
        case .poolHasNoEndpoints: return "poolHasNoEndpoints"
        case .blockHasNoColumns: return "blockHasNoColumns"
        case .allPoolEndpointsFailed: return "allPoolEndpointsFailed"
        case .serverException: return "serverException"
        case .dateValueOutOfRange: return "dateValueOutOfRange"
        case .invalidDateTime64Precision: return "invalidDateTime64Precision"
        case .invalidDecimalScale: return "invalidDecimalScale"
        case .lz4MalformedBlock: return "lz4MalformedBlock"
        case .lz4DecompressedSizeMismatch: return "lz4DecompressedSizeMismatch"
        case .unexpectedPingResponse: return "unexpectedPingResponse"
        case .compressionFrameTruncated: return "compressionFrameTruncated"
        case .compressionFrameSizeOutOfRange: return "compressionFrameSizeOutOfRange"
        case .compressionFrameChecksumMismatch: return "compressionFrameChecksumMismatch"
        case .compressionFrameUnknownMethod: return "compressionFrameUnknownMethod"
        case .compressionFrameMethodUnsupported: return "compressionFrameMethodUnsupported"
        case .compressionFrameNonePayloadSizeMismatch: return "compressionFrameNonePayloadSizeMismatch"
        case .unsupportedSelectColumnType: return "unsupportedSelectColumnType"
        case .scalarColumnTypeMismatch: return "scalarColumnTypeMismatch"
        case .scalarQueryReturnedZeroRows: return "scalarQueryReturnedZeroRows"
        case .unknownSerializationKind: return "unknownSerializationKind"
        case .sparseOffsetExceedsRowCount: return "sparseOffsetExceedsRowCount"
        case .sparseSerializationOnUnsupportedSpec: return "sparseSerializationOnUnsupportedSpec"
        case .sparseScatterTypeMismatch: return "sparseScatterTypeMismatch"
        case .unsupportedJSONColumnType: return "unsupportedJSONColumnType"
        case .rowIndexOutOfRange: return "rowIndexOutOfRange"
        case .handshakeTimedOut: return "handshakeTimedOut"
        case .sparseRowCountExceedsLimit: return "sparseRowCountExceedsLimit"
        case .lowCardinalityDictionaryIndexOutOfRange: return "lowCardinalityDictionaryIndexOutOfRange"
        case .lowCardinalityInvalidKeyType: return "lowCardinalityInvalidKeyType"
        case .dateTime64TickToNanosecondsOverflow: return "dateTime64TickToNanosecondsOverflow"
        case .emptyQueryParameterName: return "emptyQueryParameterName"
        case .emptyQuerySettingName: return "emptyQuerySettingName"
        case .internalColumnTypeCastFailure: return "internalColumnTypeCastFailure"
        case .rowEncoderUnsupportedType: return "rowEncoderUnsupportedType"
        case .rowEncoderColumnTypeMismatch: return "rowEncoderColumnTypeMismatch"
        case .rowEncoderRowMissingColumns: return "rowEncoderRowMissingColumns"
        case .rowDecoderMismatchedColumnRowCounts: return "rowDecoderMismatchedColumnRowCounts"
        case .rowDecoderUnsupportedColumnValueShape: return "rowDecoderUnsupportedColumnValueShape"
        case .nonFiniteFloatInJSONOutput: return "nonFiniteFloatInJSONOutput"
        case .insertSampleBlockMissing: return "insertSampleBlockMissing"
        case .insertColumnCountMismatch: return "insertColumnCountMismatch"
        case .insertColumnTypeUnpromotable: return "insertColumnTypeUnpromotable"
        case .insertEnumUnknownLabel: return "insertEnumUnknownLabel"
        case .codableDecodingFailure: return "codableDecodingFailure"
        case .codableEncodingFailure: return "codableEncodingFailure"
        case .cancelled: return "cancelled"
        case .malformedIPv6Address: return "malformedIPv6Address"
        }
    }

}
