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

// URL-string convenience initializer for `Configuration`. Common
// pattern for 12-factor apps that consume `DATABASE_URL` from the
// environment, secret managers, or command-line args.
//
// Supported forms:
//   clickhouse://[user[:password]@]host[:port][/database]
//   clickhouses://[user[:password]@]host[:port][/database]   (TLS)
//
// Defaults: user="default", password="", database="default",
// port=9000 (clickhouse) or 9440 (clickhouses).
//
// Multi-host URLs (`host1:9000,host2:9000`) and query parameters
// are NOT supported — those use cases call the typed initializer
// directly. Query parameters present in the URL are rejected to
// avoid silently dropping intent (e.g., a typo'd `?compression=lz4`).
extension ClickHouseClient.Configuration {

    public init(url: URL, eventLoopGroup: EventLoopGroup) throws(ClickHouseError) {
        let parsed = try Self.parse(url: url)
        self.init(
            endpoints: [.init(host: parsed.host, port: parsed.port)],
            database: parsed.database,
            user: parsed.user,
            password: parsed.password,
            eventLoopGroup: eventLoopGroup,
            transportSecurity: parsed.transportSecurity
        )
    }

    // Internal struct exposed for testability — `parse(url:)` returns the
    // raw fields without instantiating a full Configuration (which would
    // require an EventLoopGroup). Tests verify field-by-field; the public
    // initializer composes these into a Configuration.
    struct Parsed {

        let host: String
        let port: Int
        let user: String
        let password: String
        let database: String
        let transportSecurity: ClickHouseClient.TransportSecurity

    }

    static func parse(url: URL) throws(ClickHouseError) -> Parsed {
        let components = try parseComponents(url: url)
        let scheme = try parseScheme(components: components)
        let host = try parseHost(components: components)
        try rejectQueryParameters(components: components)
        let port = try parsePort(components: components, defaultPort: scheme.defaultPort)
        let database = parseDatabase(components: components)
        let transportSecurity: ClickHouseClient.TransportSecurity = scheme.useTLS
            ? .tls(ClickHouseClient.TLSOptions(serverName: .explicit(host)))
            : .plaintext
        return Parsed(
            host: host,
            port: port,
            user: components.user ?? "default",
            password: components.password ?? "",
            database: database,
            transportSecurity: transportSecurity
        )
    }

    private static func parseComponents(url: URL) throws(ClickHouseError) -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClickHouseError.invalidConfigurationURL(reason: "could not parse URL components")
        }
        return components
    }

    private struct SchemeInfo {
        let useTLS: Bool
        let defaultPort: Int
    }

    private static func parseScheme(components: URLComponents) throws(ClickHouseError) -> SchemeInfo {
        guard let scheme = components.scheme?.lowercased() else {
            throw ClickHouseError.invalidConfigurationURL(reason: "missing scheme")
        }
        switch scheme {
        case "clickhouse": return SchemeInfo(useTLS: false, defaultPort: 9000)
        case "clickhouses": return SchemeInfo(useTLS: true, defaultPort: 9440)
        default: throw ClickHouseError.invalidConfigurationURL(
            reason: "unsupported scheme '\(scheme)' (use 'clickhouse' or 'clickhouses')"
        )
        }
    }

    private static func parseHost(components: URLComponents) throws(ClickHouseError) -> String {
        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw ClickHouseError.invalidConfigurationURL(reason: "missing host")
        }
        try rejectCommaSeparatedHosts(rawHost: rawHost)
        return stripIPv6Brackets(rawHost: rawHost)
    }

    private static func rejectCommaSeparatedHosts(rawHost: String) throws(ClickHouseError) {
        if rawHost.contains(",") {
            throw ClickHouseError.invalidConfigurationURL(
                reason: "multi-host URLs (comma-separated) are not supported — use the typed initializer with multiple endpoints"
            )
        }
    }

    private static func stripIPv6Brackets(rawHost: String) -> String {
        if hasIPv6Brackets(rawHost: rawHost) {
            return String(rawHost.dropFirst().dropLast())
        }
        return rawHost
    }

    private static func hasIPv6Brackets(rawHost: String) -> Bool {
        rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
    }

    private static func rejectQueryParameters(components: URLComponents) throws(ClickHouseError) {
        if let query = components.query, !query.isEmpty {
            throw ClickHouseError.invalidConfigurationURL(
                reason: "query parameters are not supported in the connection URL — use the typed initializer for settings/compression/etc."
            )
        }
    }

    private static func parsePort(components: URLComponents, defaultPort: Int) throws(ClickHouseError) -> Int {
        guard let explicitPort = components.port else { return defaultPort }
        guard (1...65_535).contains(explicitPort) else {
            throw ClickHouseError.invalidConfigurationURL(
                reason: "port \(explicitPort) is out of range (must be 1…65535)"
            )
        }
        return explicitPort
    }

    private static func parseDatabase(components: URLComponents) -> String {
        let database = String(components.path.drop(while: { $0 == "/" }))
        return database.isEmpty ? "default" : database
    }

}
