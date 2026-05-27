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

import DXCore
import Tracing

enum TracePropagation {

    @inline(__always)
    static func inject(_ context: ServiceContext) -> [NatsHeader] {
        var carrier: [NatsHeader] = []
        InstrumentationSystem.instrument.inject(context, into: &carrier, using: HeaderInjector())
        return carrier
    }

    @inline(__always)
    static func injectCurrent() -> [NatsHeader] {
        inject(ServiceContext.current ?? .topLevel)
    }

    @inline(__always)
    static func extract(_ headers: [NatsHeader]) -> ServiceContext {
        var context = ServiceContext.topLevel
        InstrumentationSystem.instrument.extract(headers, into: &context, using: HeaderExtractor())
        return context
    }

    struct HeaderInjector: Injector {

        typealias Carrier = [NatsHeader]

        func inject(_ value: String, forKey key: String, into carrier: inout [NatsHeader]) {
            carrier.append(NatsHeader(name: key, value: value))
        }
    }

    struct HeaderExtractor: Extractor {

        typealias Carrier = [NatsHeader]

        func extract(key: String, from carrier: [NatsHeader]) -> String? {
            switch lookupHeader(named: key, in: carrier) {
            case .found(let value): return value
            case .notFound: return nil
            }
        }
    }
}

@inline(__always)
internal func lookupHeader(named name: String, in headers: [NatsHeader]) -> Lookup<String> {
    for header in headers where header.name == name {
        return .found(header.value)
    }
    return .notFound
}
