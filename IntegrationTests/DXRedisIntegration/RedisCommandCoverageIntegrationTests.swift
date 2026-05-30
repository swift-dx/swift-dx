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
import DXRedis
import Testing

// Exercises every storage data type and a broad command set through the generic
// send/sendArray escape hatch against a live Redis, proving the protocol-uniform
// claim empirically and stressing the decoder on every RESP reply shape: simple
// strings, bulk strings, integers, doubles rendered as bulk, flat and nested
// arrays, null elements, and server errors. Pub/Sub and streams are out of scope
// by request; this is storage manipulation only.
@Suite("Redis command coverage", .enabled(if: RedisIntegration.isEnabled), .serialized)
struct RedisCommandCoverageIntegrationTests {

    private func client() throws -> RedisClient {
        try RedisIntegration.makeClient(database: 13)
    }

    private func key(_ suffix: String) -> String {
        RedisIntegration.uniqueKey(suffix).description
    }

    @Test("string and number commands decode their replies")
    func strings() async throws {
        let client = try client()
        let k = key("str")
        #expect(try await client.send(.init("SET", k, "hello")).stringValue() == "OK")
        #expect(try await client.send(.init("APPEND", k, " world")).integerValue() == 11)
        #expect(try await client.send(.init("STRLEN", k)).integerValue() == 11)
        #expect(try await client.send(.init("GETRANGE", k, "0", "4")).stringValue() == "hello")
        let counter = key("ctr")
        #expect(try await client.send(.init("INCR", counter)).integerValue() == 1)
        #expect(try await client.send(.init("INCRBY", counter, "10")).integerValue() == 11)
        #expect(try await client.send(.init("DECRBY", counter, "5")).integerValue() == 6)
        #expect(try await client.send(.init("INCRBYFLOAT", counter, "0.5")).stringValue() == "6.5")
        #expect(try await client.send(.init("SETNX", counter, "x")).integerValue() == 0)
        #expect(try await client.send(.init("GETDEL", k)).stringValue() == "hello world")
        #expect(try await client.send(.init("GET", k)).isNull)
        await client.shutdown()
    }

    @Test("hash commands decode integers, bulks, and field/value arrays")
    func hashes() async throws {
        let client = try client()
        let h = key("hash")
        #expect(try await client.send(.init("HSET", h, "a", "1", "b", "2")).integerValue() == 2)
        #expect(try await client.send(.init("HGET", h, "a")).stringValue() == "1")
        #expect(try await client.send(.init("HLEN", h)).integerValue() == 2)
        #expect(try await client.send(.init("HEXISTS", h, "a")).integerValue() == 1)
        #expect(try await client.send(.init("HINCRBY", h, "a", "9")).integerValue() == 10)
        let all = try await client.sendArray(.init("HGETALL", h))
        #expect(all.count == 4)
        let pairs = try await client.send(.init("HMGET", h, "a", "missing", "b")).arrayValue()
        #expect(pairs.count == 3)
        #expect(pairs[1].isNull)
        await client.shutdown()
    }

    @Test("list commands decode push counts, ranges, and pops")
    func lists() async throws {
        let client = try client()
        let l = key("list")
        #expect(try await client.send(.init("RPUSH", l, "a", "b", "c")).integerValue() == 3)
        #expect(try await client.send(.init("LLEN", l)).integerValue() == 3)
        let range = try await client.sendArray(.init("LRANGE", l, "0", "-1"))
        #expect(range.count == 3)
        #expect(try range.stringLookup(at: 0) == Lookup.found("a"))
        #expect(try await client.send(.init("LINDEX", l, "1")).stringValue() == "b")
        #expect(try await client.send(.init("LPOP", l)).stringValue() == "a")
        #expect(try await client.send(.init("LSET", l, "0", "B")).stringValue() == "OK")
        await client.shutdown()
    }

    @Test("set commands decode membership, cardinality, and member arrays")
    func sets() async throws {
        let client = try client()
        let s1 = key("set1")
        let s2 = key("set2")
        #expect(try await client.send(.init("SADD", s1, "a", "b", "c")).integerValue() == 3)
        #expect(try await client.send(.init("SCARD", s1)).integerValue() == 3)
        #expect(try await client.send(.init("SISMEMBER", s1, "a")).integerValue() == 1)
        #expect(try await client.send(.init("SISMEMBER", s1, "z")).integerValue() == 0)
        _ = try await client.send(.init("SADD", s2, "b", "c", "d"))
        #expect(try await client.sendArray(.init("SINTER", s1, s2)).count == 2)
        let flags = try await client.send(.init("SMISMEMBER", s1, "a", "z")).arrayValue()
        #expect(try flags[0].integerValue() == 1)
        #expect(try flags[1].integerValue() == 0)
        await client.shutdown()
    }

    @Test("sorted-set commands decode scores as bulk doubles and member arrays")
    func sortedSets() async throws {
        let client = try client()
        let z = key("zset")
        #expect(try await client.send(.init("ZADD", z, "1", "a", "2", "b", "3", "c")).integerValue() == 3)
        #expect(try await client.send(.init("ZCARD", z)).integerValue() == 3)
        #expect(try await client.send(.init("ZSCORE", z, "b")).stringValue() == "2")
        #expect(try await client.send(.init("ZRANK", z, "c")).integerValue() == 2)
        #expect(try await client.send(.init("ZINCRBY", z, "1.5", "a")).stringValue() == "2.5")
        let withScores = try await client.sendArray(.init("ZRANGE", z, "0", "-1", "WITHSCORES"))
        #expect(withScores.count == 6)
        let popped = try await client.sendArray(.init("ZPOPMIN", z))
        #expect(popped.count == 2)
        await client.shutdown()
    }

    @Test("bitmap and HyperLogLog commands decode their integer replies")
    func bitmapsAndHyperLogLog() async throws {
        let client = try client()
        let b = key("bits")
        #expect(try await client.send(.init("SETBIT", b, "7", "1")).integerValue() == 0)
        #expect(try await client.send(.init("GETBIT", b, "7")).integerValue() == 1)
        #expect(try await client.send(.init("BITCOUNT", b)).integerValue() == 1)
        let hll = key("hll")
        #expect(try await client.send(.init("PFADD", hll, "x", "y", "z")).integerValue() == 1)
        #expect(try await client.send(.init("PFCOUNT", hll)).integerValue() == 3)
        await client.shutdown()
    }

    @Test("geo commands decode nested coordinate arrays")
    func geo() async throws {
        let client = try client()
        let g = key("geo")
        #expect(try await client.send(.init("GEOADD", g, "13.361389", "38.115556", "palermo", "15.087269", "37.502669", "catania")).integerValue() == 2)
        let distance = try await client.send(.init("GEODIST", g, "palermo", "catania", "km")).stringValue()
        let kilometers = Double(distance) ?? 0
        #expect(kilometers > 100)
        let positions = try await client.sendArray(.init("GEOPOS", g, "palermo"))
        #expect(positions.count == 1)
        let firstPosition = try positions.nestedArray(at: 0)
        #expect(firstPosition.count == 2)
        let nearby = try await client.sendArray(.init("GEOSEARCH", g, "FROMMEMBER", "palermo", "BYRADIUS", "200", "km", "ASC"))
        #expect(nearby.count == 2)
        await client.shutdown()
    }

    @Test("keyspace commands decode type, ttl, rename, and copy replies")
    func keyspace() async throws {
        let client = try client()
        let k = key("ks")
        let renamed = key("ks-renamed")
        let copied = key("ks-copied")
        _ = try await client.send(.init("SET", k, "v"))
        #expect(try await client.send(.init("TYPE", k)).stringValue() == "string")
        #expect(try await client.send(.init("EXPIRE", k, "100")).integerValue() == 1)
        #expect(try await client.send(.init("TTL", k)).integerValue() > 0)
        #expect(try await client.send(.init("PERSIST", k)).integerValue() == 1)
        let encoding = try await client.send(.init("OBJECT", "ENCODING", k)).stringValue()
        #expect(["embstr", "raw", "int"].contains(encoding))
        #expect(try await client.send(.init("RENAME", k, renamed)).stringValue() == "OK")
        #expect(try await client.send(.init("COPY", renamed, copied)).integerValue() == 1)
        #expect(try await client.send(.init("EXISTS", renamed, copied)).integerValue() == 2)
        await client.shutdown()
    }

    @Test("EVAL returns every RESP shape: integer, bulk, status, nil, flat and nested arrays")
    func luaReplyShapes() async throws {
        let client = try client()
        #expect(try await client.send(.init("EVAL", "return 42", "0")).integerValue() == 42)
        #expect(try await client.send(.init("EVAL", "return 'hello'", "0")).stringValue() == "hello")
        #expect(try await client.send(.init("EVAL", "return redis.status_reply('GOOD')", "0")).stringValue() == "GOOD")
        #expect(try await client.send(.init("EVAL", "return nil", "0")).isNull)
        let flat = try await client.sendArray(.init("EVAL", "return {1, 2, 3}", "0"))
        #expect(flat.count == 3)
        #expect(try flat.integerValue(at: 0) == 1)
        let nested = try await client.sendArray(.init("EVAL", "return {1, 'two', {3, 'four'}}", "0"))
        #expect(nested.count == 3)
        let child = try nested.nestedArray(at: 2)
        #expect(child.count == 2)
        #expect(try child.stringLookup(at: 1) == Lookup.found("four"))
        await client.shutdown()
    }

    @Test("EVALSHA runs a cached script loaded with SCRIPT LOAD")
    func evalsha() async throws {
        let client = try client()
        let target = key("sha")
        let digest = try await client.send(.init("SCRIPT", "LOAD", "return redis.call('SET', KEYS[1], ARGV[1])")).stringValue()
        #expect(try await client.send(.init("EVALSHA", digest, "1", target, "stored")).stringValue() == "OK")
        #expect(try await client.getString(RedisKey(target)) == Lookup.found("stored"))
        await client.shutdown()
    }

    @Test("a wrong-type operation surfaces the server error through the typed error")
    func wrongTypeError() async throws {
        let client = try client()
        let k = key("wrong")
        _ = try await client.send(.init("SET", k, "scalar"))
        await #expect(throws: RedisError.self) {
            _ = try await client.send(.init("LPUSH", k, "x"))
        }
        await client.shutdown()
    }
}
