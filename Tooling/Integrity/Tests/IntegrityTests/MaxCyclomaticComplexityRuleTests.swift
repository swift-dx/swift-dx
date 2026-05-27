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

import Testing
@testable import Integrity

@Suite
struct MaxCyclomaticComplexityRuleTests {

    @Test
    func acceptsLinearFunction() {
        let contents = """
        func work() {
            let a = 1
            let b = 2
            print(a + b)
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(MaxCyclomaticComplexityRule().check(file).isEmpty)
    }

    @Test
    func acceptsTwoBranches() {
        let contents = """
        func choose(flag: Bool) -> Int {
            if flag {
                return 1
            } else {
                return 0
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(MaxCyclomaticComplexityRule().check(file).isEmpty)
    }

    @Test
    func flagsAboveThreshold() {
        let contents = """
        func route(value: Int) -> Int {
            if value < 0 { return -1 }
            if value == 0 { return 0 }
            if value < 10 { return 1 }
            if value < 100 { return 2 }
            return 3
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("complexity"))
    }

    @Test
    func countsAndAndOrOperators() {
        let contents = """
        func combined(a: Bool, b: Bool, c: Bool, d: Bool) -> Bool {
            return a && b || c && d
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func leafSwitchCasesIgnoredEvenWithoutDefault() {
        let contents = """
        enum Status { case ok, partial, failed }
        func describe(_ status: Status) -> String {
            switch status {
            case .ok: return "ok"
            case .partial: return "partial"
            case .failed: return "failed"
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(MaxCyclomaticComplexityRule().check(file).isEmpty)
    }

    @Test
    func countsCatchClause() {
        let contents = """
        func work() {
            do {
                try thing()
            } catch is FooError {
                handle()
            } catch is BarError {
                handle()
            } catch is BazError {
                handle()
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func nestedFunctionEvaluatedSeparately() {
        let contents = """
        func outer() {
            if a {
                return
            }
            func inner(value: Int) -> Int {
                if value < 0 { return 0 }
                if value < 10 { return 1 }
                if value < 100 { return 2 }
                if value < 1000 { return 3 }
                return 4
            }
            inner(value: 0)
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
        #expect(violations[0].message.contains("inner"))
    }

    @Test
    func closureExpressionsNotCountedInEnclosing() {
        let contents = """
        func render() {
            paint { a, b in
                if a && b {
                    print(1)
                } else if a || b {
                    print(2)
                } else {
                    print(3)
                }
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(MaxCyclomaticComplexityRule().check(file).isEmpty)
    }

    @Test
    func ternaryCounts() {
        let contents = """
        func classify(x: Int) -> String {
            return x > 0 ? (x > 10 ? "big" : "small") : (x < -10 ? "neg" : "small")
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
    }

    @Test
    func leafSwitchCasesDoNotCountTowardComplexity() {
        let contents = """
        enum Verb { case a, b, c, d, e, f, g }
        func render(_ verb: Verb) -> String {
            switch verb {
            case .a: return "alpha"
            case .b: return "beta"
            case .c: return "gamma"
            case .d: return "delta"
            case .e: return "epsilon"
            case .f: return "zeta"
            case .g: return "eta"
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        #expect(MaxCyclomaticComplexityRule().check(file).isEmpty)
    }

    @Test
    func nonLeafSwitchCasesStillCount() {
        let contents = """
        func handle(verb: Int) -> Int {
            switch verb {
            case 1:
                let x = 1
                return x + 1
            case 2:
                let x = 2
                return x + 1
            case 3:
                let x = 3
                return x + 1
            case 4:
                let x = 4
                return x + 1
            default: return 0
            }
        }
        """
        let file = SourceFile(path: "/tmp/Sample.swift", contents: contents)
        let violations = MaxCyclomaticComplexityRule().check(file)
        #expect(violations.count == 1)
    }
}
