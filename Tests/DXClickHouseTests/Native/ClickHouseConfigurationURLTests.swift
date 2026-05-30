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

@testable import DXClickHouse
import Foundation
import NIOPosix
import Testing

@Suite("ClickHouseClient.Configuration — URL initializer")
struct ClickHouseConfigurationURLTests {

    private static func parse(_ string: String) throws -> ClickHouseClient.Configuration.Parsed {
        guard let url = URL(string: string) else {
            Issue.record("URL string '\(string)' didn't parse to URL")
            return try ClickHouseClient.Configuration.parse(url: URL(string: "clickhouse://x")!)
        }
        return try ClickHouseClient.Configuration.parse(url: url)
    }

    // MARK: - Successful parse paths

    @Test("clickhouse:// with just host uses defaults for port (9000), user (default), password (empty), database (default)")
    func minimalClickhouseURL() throws {
        let parsed = try Self.parse("clickhouse://ch.example.com")
        #expect(parsed.host == "ch.example.com")
        #expect(parsed.port == 9000)
        #expect(parsed.user == "default")
        #expect(parsed.password == "")
        #expect(parsed.database == "default")
        guard case .plaintext = parsed.transportSecurity else {
            Issue.record("expected .plaintext, got \(parsed.transportSecurity)")
            return
        }
    }

    @Test("clickhouses:// defaults to port 9440 and constructs TLSOptions with serverName from host")
    func clickhousesURLEnablesTLS() throws {
        let parsed = try Self.parse("clickhouses://ch.example.com")
        #expect(parsed.port == 9440)
        guard case .tls(let options) = parsed.transportSecurity else {
            Issue.record("expected .tls, got \(parsed.transportSecurity)")
            return
        }
        #expect(options.serverName == .explicit("ch.example.com"))
    }

    @Test("explicit port overrides the scheme's default")
    func explicitPortOverridesDefault() throws {
        let parsed1 = try Self.parse("clickhouse://ch.example.com:8123")
        #expect(parsed1.port == 8123)
        let parsed2 = try Self.parse("clickhouses://ch.example.com:9001")
        #expect(parsed2.port == 9001)
    }

    @Test("user and password from URL userInfo are preserved verbatim")
    func userPasswordFromURL() throws {
        let parsed = try Self.parse("clickhouse://alice:s3cr3t@ch.example.com")
        #expect(parsed.user == "alice")
        #expect(parsed.password == "s3cr3t")
    }

    @Test("user without password is preserved (password defaults to empty)")
    func userWithoutPassword() throws {
        let parsed = try Self.parse("clickhouse://alice@ch.example.com")
        #expect(parsed.user == "alice")
        #expect(parsed.password == "")
    }

    @Test(
        "port boundaries are validated: 0 and >65535 throw, 1 and 65535 are accepted",
        arguments: [
            (0, false),
            (1, true),
            (9_000, true),
            (65_535, true),
            (65_536, false),
            (99_999, false),
        ] as [(Int, Bool)]
    )
    func portBoundaryHandling(args: (Int, Bool)) throws {
        let (port, expectAccepted) = args
        let urlString = "clickhouse://ch.example.com:\(port)/db"
        var thrown: Error?
        var parsedPort: Int?
        do {
            parsedPort = try Self.parse(urlString).port
        } catch {
            thrown = error
        }
        if expectAccepted {
            #expect(thrown == nil, "port \(port) should be accepted; got error \(String(describing: thrown))")
            #expect(parsedPort == port)
        } else {
            let received = try #require(thrown, "port \(port) should be rejected; got parsedPort=\(String(describing: parsedPort))")
            guard case ClickHouseError.invalidConfigurationURL = received else {
                Issue.record("port \(port) should throw invalidConfigurationURL, got \(received)")
                return
            }
        }
    }

    @Test("URL with non-numeric port fails URL construction (Foundation rejects), giving a clean nil at the URL layer")
    func nonNumericPortFailsURLConstruction() {
        // We can't even reach the parser — `URL(string:)` returns nil
        // for a non-numeric port. The user gets a Swift-level Optional
        // signal at construction. Pin the contract so a future change
        // that swaps to URLComponents-only construction (which DOES
        // accept some weird ports) doesn't slip past.
        #expect(URL(string: "clickhouse://host:notaport/db") == nil)
        #expect(URL(string: "clickhouse://host:-1/db") == nil)
    }

    @Test("very long hostnames parse cleanly so the OS-level connect (not our code) is the failure boundary")
    func longHostnamesParseCleanly() throws {
        let longHost = String(repeating: "a", count: 500) + ".example.com"
        let parsed = try Self.parse("clickhouse://\(longHost)/db")
        #expect(parsed.host == longHost)
        // OS will reject at DNS time (max label is 63 chars) — but
        // that's the right layer to enforce host-string validity.
    }

    @Test("URL with extra path segments lands the whole path-after-slash in the database field")
    func extraPathSegmentsBecomePartOfDatabase() throws {
        // CH server validates the database name; we don't pre-reject
        // slashes. This test pins the documented behavior so a future
        // refactor that adds client-side validation has to update the
        // contract intentionally.
        let parsed = try Self.parse("clickhouse://host/db/with/slashes")
        #expect(parsed.database == "db/with/slashes")
    }

    @Test("empty trailing query (the literal `?` with nothing after) is treated as no query")
    func emptyTrailingQueryIsAccepted() throws {
        let parsed = try Self.parse("clickhouse://host:9000/db?")
        #expect(parsed.host == "host")
        #expect(parsed.port == 9000)
        #expect(parsed.database == "db")
    }

    @Test("comma-separated host lists in the URL form are rejected explicitly rather than parsed as a single weird hostname")
    func commaSeparatedHostsAreRejected() throws {
        // Foundation accepts `clickhouse://host1,host2/db` as a URL
        // with hostname literally `"host1,host2"`. Without an explicit
        // check it would silently fail at connect time with a confusing
        // DNS error. The typed `init(configuration:)` with multiple
        // endpoints is the correct multi-host path.
        var thrown: Error?
        do {
            _ = try Self.parse("clickhouse://host1,host2/db")
        } catch {
            thrown = error
        }
        let received = try #require(thrown)
        guard case ClickHouseError.invalidConfigurationURL(let reason) = received else {
            Issue.record("expected invalidConfigurationURL, got \(received)")
            return
        }
        #expect(reason.contains("multi-host"), "error reason should mention multi-host: \(reason)")
    }

    @Test("IPv6 host URLs are parsed without the bracket-quoting (NIO connect wants the bare address)")
    func ipv6HostStripsBrackets() throws {
        let parsed = try Self.parse("clickhouse://[::1]:9000/analytics")
        #expect(parsed.host == "::1", "expected bare IPv6 host, got \(parsed.host)")
        #expect(parsed.port == 9000)
        #expect(parsed.database == "analytics")
    }

    @Test("IPv6 with full address survives the bracket-strip and the database/credentials are intact")
    func ipv6FullAddressPreservesAllFields() throws {
        let parsed = try Self.parse("clickhouses://alice:secret@[2001:db8::1]:9441/events")
        #expect(parsed.host == "2001:db8::1")
        #expect(parsed.port == 9441)
        #expect(parsed.user == "alice")
        #expect(parsed.password == "secret")
        #expect(parsed.database == "events")
        guard case .tls = parsed.transportSecurity else {
            Issue.record("expected .tls, got \(parsed.transportSecurity)")
            return
        }
    }

    @Test("percent-encoded user and password are decoded so credentials survive special characters")
    func percentEncodedCredentialsAreDecoded() throws {
        // Foundation's bare URL.user/URL.password decode asymmetrically
        // (user decodes, password doesn't), which would leave a
        // password like `p@ss` (encoded as `p%40ss`) literally
        // `p%40ss` on the wire and fail authentication. Parsing via
        // URLComponents fixes the asymmetry.
        let parsed = try Self.parse("clickhouse://us%40er:p%40ss%21word@ch.example.com")
        #expect(parsed.user == "us@er", "expected percent-decoded user, got \(parsed.user)")
        #expect(parsed.password == "p@ss!word", "expected percent-decoded password, got \(parsed.password)")
    }

    @Test("database from path strips the leading slash")
    func databaseFromPathStripsLeadingSlash() throws {
        let parsed = try Self.parse("clickhouse://ch.example.com/analytics")
        #expect(parsed.database == "analytics")
    }

    @Test("empty path falls back to 'default' database")
    func emptyPathFallsBackToDefaultDatabase() throws {
        let parsed = try Self.parse("clickhouse://ch.example.com/")
        #expect(parsed.database == "default")
    }

    @Test("database from a path with multiple leading slashes (e.g., '//analytics') strips them all")
    func databaseFromMultiSlashPathIsNormalized() throws {
        // Pre-fix: dropFirst() stripped only one leading slash, so
        // `clickhouse://host//analytics` produced database "/analytics"
        // which would be rejected by the server with a confusing error.
        // Post-fix: strip every leading slash and resolve "" to default.
        let parsed = try Self.parse("clickhouse://ch.example.com//analytics")
        #expect(parsed.database == "analytics")
    }

    @Test("database from a path of only slashes resolves to 'default'")
    func slashOnlyPathResolvesToDefault() throws {
        let parsed = try Self.parse("clickhouse://ch.example.com///")
        #expect(parsed.database == "default")
    }

    @Test("a fully-populated URL parses every field correctly")
    func fullyPopulatedURL() throws {
        let parsed = try Self.parse("clickhouses://alice:secret@ch.example.com:9441/events")
        #expect(parsed.host == "ch.example.com")
        #expect(parsed.port == 9441)
        #expect(parsed.user == "alice")
        #expect(parsed.password == "secret")
        #expect(parsed.database == "events")
        guard case .tls(let options) = parsed.transportSecurity else {
            Issue.record("expected .tls")
            return
        }
        #expect(options.serverName == .explicit("ch.example.com"))
    }

    // MARK: - Error paths

    @Test("URL with unsupported scheme (e.g., http://) throws invalidConfigurationURL")
    func unsupportedSchemeThrows() {
        #expect(throws: ClickHouseError.self) {
            try Self.parse("http://ch.example.com")
        }
    }

    @Test("URL with no host throws invalidConfigurationURL")
    func noHostThrows() {
        #expect(throws: ClickHouseError.self) {
            try Self.parse("clickhouse:///mydb")
        }
    }

    @Test("URL with query parameters throws (silent drops would mask intent)")
    func queryParametersThrow() {
        var thrown: Error?
        do {
            _ = try Self.parse("clickhouse://ch.example.com?compression=lz4")
        } catch {
            thrown = error
        }
        let received = try? #require(thrown)
        guard case ClickHouseError.invalidConfigurationURL(let reason) = received as? ClickHouseError ?? .poolHasNoEndpoints else {
            Issue.record("expected invalidConfigurationURL")
            return
        }
        #expect(reason.contains("query parameters"))
    }

    @Test("scheme matching is case-insensitive ('Clickhouse://' works)")
    func schemeMatchingIsCaseInsensitive() throws {
        let parsed = try Self.parse("Clickhouse://ch.example.com")
        guard case .plaintext = parsed.transportSecurity else {
            Issue.record("expected .plaintext")
            return
        }
        let parsedTLS = try Self.parse("CLICKHOUSES://ch.example.com")
        guard case .tls = parsedTLS.transportSecurity else {
            Issue.record("expected .tls")
            return
        }
    }

    // MARK: - End-to-end Configuration init

    @Test("the public init(url:eventLoopGroup:) composes a Configuration with the parsed fields")
    func publicInitializerComposesConfiguration() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let url = URL(string: "clickhouses://alice:secret@ch.internal:9450/analytics")!
        let config = try ClickHouseClient.Configuration(url: url, eventLoopGroup: group)
        #expect(config.endpoints.count == 1)
        #expect(config.endpoints[0].host == "ch.internal")
        #expect(config.endpoints[0].port == 9450)
        #expect(config.user == "alice")
        #expect(config.password == "secret")
        #expect(config.database == "analytics")
        guard case .tls(let options) = config.transportSecurity else {
            Issue.record("expected .tls")
            return
        }
        #expect(options.serverName == .explicit("ch.internal"))
    }

}
