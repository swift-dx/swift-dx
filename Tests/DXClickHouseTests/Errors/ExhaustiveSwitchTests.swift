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

import DXClickHouse
import Foundation
import Testing

// Pins the exhaustive-switch contract for every public error enum the
// library exposes. The whole point of typed errors is that adding a
// case is a SemVer breaking change; this file gives the compiler the
// chance to flag that break at PR time before downstream code does.
//
// To preserve the catch, no `default:` branch is used in any switch.
@Suite("Exhaustive switches over every public ClickHouse error enum")
struct ClickHouseExhaustiveSwitchTests {

    @Test("Every ClickHouseError case is reachable through an exhaustive switch")
    func clickHouseErrorExhaustiveSwitch() {
        let samples: [ClickHouseError] = [
            .connectionFailed(reason: "x"),
            .socketIOFailed(errno: 1, syscall: "send"),
            .unexpectedEOF(bytesExpected: 8),
            .protocolError(stage: "handshake", message: "bad"),
            .queryFailed(serverException: ClickHouseServerException(code: 1, name: "X", message: "x")),
            .reconnectExhausted(attempts: 3),
            .endpointsExhausted(failures: []),
            .queryTimeout(elapsed: .milliseconds(100)),
        ]
        #expect(samples.count == 8)
        var hits = Set<String>()
        for error in samples {
            let label: String
            switch error {
            case .connectionFailed:    label = "connectionFailed"
            case .socketIOFailed:      label = "socketIOFailed"
            case .unexpectedEOF:       label = "unexpectedEOF"
            case .protocolError:       label = "protocolError"
            case .queryFailed:         label = "queryFailed"
            case .reconnectExhausted:  label = "reconnectExhausted"
            case .endpointsExhausted:  label = "endpointsExhausted"
            case .queryTimeout:        label = "queryTimeout"
            }
            hits.insert(label)
        }
        #expect(hits.count == 8, "case count drifted, update the test alongside the enum")
    }

    @Test("Every ClickHouseConnectionPool.Failure case is reachable")
    func poolFailureExhaustiveSwitch() {
        let samples: [ClickHouseConnectionPool.Failure] = [
            .poolClosed,
            .acquireTimedOut(after: .milliseconds(500)),
            .openFailed(reason: "x"),
            .allEndpointsFailed(failures: []),
        ]
        #expect(samples.count == 4)
        var hits = Set<String>()
        for failure in samples {
            let label: String
            switch failure {
            case .poolClosed:          label = "poolClosed"
            case .acquireTimedOut:     label = "acquireTimedOut"
            case .openFailed:          label = "openFailed"
            case .allEndpointsFailed:  label = "allEndpointsFailed"
            }
            hits.insert(label)
        }
        #expect(hits.count == 4)
    }

    @Test("Exhaustive switch round-trips every ClickHouseError payload")
    func payloadRoundTripExhaustive() {
        let cases: [(ClickHouseError, String)] = [
            (.connectionFailed(reason: "a"), "connectionFailed:a"),
            (.socketIOFailed(errno: 11, syscall: "recv"), "socketIOFailed:recv:11"),
            (.unexpectedEOF(bytesExpected: 42), "unexpectedEOF:42"),
            (.protocolError(stage: "s", message: "m"), "protocolError:s:m"),
            (.queryFailed(serverException: ClickHouseServerException(code: 7, name: "n", message: "M")), "queryFailed:7:n"),
            (.reconnectExhausted(attempts: 4), "reconnectExhausted:4"),
            (.endpointsExhausted(failures: [
                ClickHouseEndpointFailure(host: "h", port: 1, reason: "r"),
            ]), "endpointsExhausted:1"),
            (.queryTimeout(elapsed: .milliseconds(99)), "queryTimeout"),
        ]
        for (error, expectedPrefix) in cases {
            let computed: String
            switch error {
            case .connectionFailed(let reason):
                computed = "connectionFailed:\(reason)"
            case .socketIOFailed(let errno, let syscall):
                computed = "socketIOFailed:\(syscall):\(errno)"
            case .unexpectedEOF(let bytesExpected):
                computed = "unexpectedEOF:\(bytesExpected)"
            case .protocolError(let stage, let message):
                computed = "protocolError:\(stage):\(message)"
            case .queryFailed(let serverException):
                computed = "queryFailed:\(serverException.code):\(serverException.name)"
            case .reconnectExhausted(let attempts):
                computed = "reconnectExhausted:\(attempts)"
            case .endpointsExhausted(let failures):
                computed = "endpointsExhausted:\(failures.count)"
            case .queryTimeout:
                computed = "queryTimeout"
            }
            #expect(computed.hasPrefix(expectedPrefix), "expected \(expectedPrefix) prefix, got \(computed)")
        }
    }

    @Test("CustomStringConvertible is non-empty for every case")
    func descriptionIsAlwaysNonEmpty() {
        let samples: [ClickHouseError] = [
            .connectionFailed(reason: "a"),
            .socketIOFailed(errno: 1, syscall: "s"),
            .unexpectedEOF(bytesExpected: 1),
            .protocolError(stage: "s", message: "m"),
            .queryFailed(serverException: ClickHouseServerException(code: 1, name: "N", message: "M")),
            .reconnectExhausted(attempts: 1),
            .endpointsExhausted(failures: []),
            .queryTimeout(elapsed: .milliseconds(1)),
        ]
        for error in samples {
            #expect(!error.description.isEmpty, "\(error) had empty description")
        }
    }

    @Test("Equatable conformance distinguishes every case from every other case")
    func crossCaseInequality() {
        let one: ClickHouseError = .connectionFailed(reason: "a")
        let two: ClickHouseError = .socketIOFailed(errno: 1, syscall: "s")
        let three: ClickHouseError = .unexpectedEOF(bytesExpected: 1)
        let four: ClickHouseError = .protocolError(stage: "s", message: "m")
        let five: ClickHouseError = .queryFailed(serverException: ClickHouseServerException(code: 1, name: "N", message: "M"))
        let six: ClickHouseError = .reconnectExhausted(attempts: 1)
        let seven: ClickHouseError = .endpointsExhausted(failures: [])
        let eight: ClickHouseError = .queryTimeout(elapsed: .milliseconds(1))
        let allCases = [one, two, three, four, five, six, seven, eight]
        for (i, left) in allCases.enumerated() {
            for (j, right) in allCases.enumerated() where i != j {
                #expect(left != right, "case \(i) compared equal to case \(j)")
            }
        }
    }
}
