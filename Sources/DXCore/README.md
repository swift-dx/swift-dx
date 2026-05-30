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

# DXCore

DXCore is the shared foundation library used internally by every other DX
library in the SwiftDX monorepo. It collects the low-level primitives that
two or more libraries need (codecs, hashing, byte scanning, ASCII helpers,
crypto primitives, JSON model, callback typealiases, message handler
protocol) so each library does not reinvent them. Most symbols are
`package` access and are invisible to external consumers; only the few
types that participate in user-facing APIs of higher-level libraries are
`public`.

## What's in it

- **Encoding** — Base32, Base64, Base64URL, Radix conversions.
- **Hashing** — CRC16.
- **Bytes** — `ByteScan`, `Ascii`, `Utf8`, `JSONScan` byte-level scanners
  and validators.
- **JSON** — value model (`JSONValue`, `JSONObject`, `JSONString`,
  `JSONNumber`), streaming reader, parser, parse limits, typed parse
  errors.
- **Identifiers** — `HexIdGenerator` for atomic counter-based hex IDs.
- **Lookups** — `Lookup<Value>` enum (replaces Optional at lookup
  boundaries with named `.found` / `.notFound` cases).
- **Messaging** — `DXCallback` typealias and `DXMessageHandler` protocol
  used across libraries that offer callback overloads of async APIs.
- **Time** — `TimeSpan` value type with nanosecond-precision arithmetic.

## Public surface

The symbols below are `public` and re-exported through higher-level
libraries (`DXJetStream`, `DXRedis`, `DXClickHouse`, `DXJSONSchema`)
that depend on `DXCore`:

- `DXCallback<Value, Failure: Error>` — the canonical one-shot callback
  typealias every library uses for its callback overload variants.
- `DXMessageHandler<Message, Failure>` — the canonical continuous-stream
  handler protocol every library uses for its callback subscription
  variants.
- `Lookup<Value>` — named alternative to `Optional` for lookup results.
- `TimeSpan` — typed duration value used by configuration types and
  per-operation timeouts across libraries.

Everything else (codecs, hashing, byte scanners, JSON model, identifiers)
is `package` access. It is reachable across the SwiftDX package but
invisible when an external project imports DXCore directly.

## How it's used

DXCore is consumed transitively. A downstream project depending on, for
example, `DXClickHouse` already gets the DXCore public surface through
that library's re-exports — no direct `import DXCore` is required.

Direct `import DXCore` is supported but exposes only the public surface
listed above; it is not a usage destination on its own.

## Stability

The `public` symbols listed under **Public surface** are covered by
SwiftDX's SemVer commitment: removing or renaming any of them is a
breaking change.

All `package`-access symbols are internal infrastructure. They can move,
rename, or disappear in any release without a SemVer bump because they
are not visible to external consumers. Do not depend on them by copying
the source; if you need a utility currently living in DXCore, file an
issue requesting it be promoted to `public` on the appropriate library.
