<!--
===----------------------------------------------------------------------===
This source file is part of the SwiftDX open source project

Copyright (c) 2026 SwiftDX Contributors
Licensed under Apache License v2.0. See LICENSE for license information.

SPDX-License-Identifier: Apache-2.0
===----------------------------------------------------------------------===
-->

# DXJSONSchema

JSON Schema Draft 2020-12 validator. Compile a schema once, validate many
instances against it. The instance parser is a Foundation-free byte parser
in `DXCore`; strings are sliced from the source buffer rather than copied.
A hot-swappable, type-grouped registry handles many schemas with atomic
bulk updates and parallel batch verification.

## Quick start

```swift
import DXJSONSchema

let schema = try JSONSchema.compile(#"""
{
  "type": "object",
  "required": ["id", "total"],
  "properties": {
    "id":    { "type": "integer", "minimum": 1 },
    "total": { "type": "number", "minimum": 0 }
  }
}
"""#)

let result = schema.validate(#"{"id": 42, "total": 19.99}"#)
if result.isValid {
    // accept
} else {
    for violation in result.violations {
        print("\(violation.instanceLocation): \(violation.message)")
    }
}
```

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swift-dx/swift-dx", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(
        name: "MyService",
        dependencies: [
            .product(name: "DXJSONSchema", package: "swift-dx"),
        ]
    ),
]
```

```swift
import DXJSONSchema
```

## Core concepts

### Compile once, validate many

`JSONSchema.compile` is the one-time step: it parses the schema, resolves
references, and builds a flat compiled document. It `throws(JSONSchemaError)`
because a malformed schema is a programmer/configuration error that should
surface at load time, not per request.

`validate` never throws. It returns a `SchemaValidationResult` describing the
outcome, including every violation with its JSON-Pointer location. A compiled
`JSONSchema` is `Sendable` and immutable — compile it once at startup and share
the value across concurrent tasks.

```swift
let schema = try JSONSchema.compile(schemaText)   // once
let result = schema.validate(instanceBytes)        // many, concurrently
```

### Input forms

Both `compile` and `validate` accept the canonical SwiftDX input forms. The
performance primitive is raw `[UInt8]`; every other form converts to it and
delegates.

| Form | `compile` | `validate` | Notes |
|------|-----------|------------|-------|
| `[UInt8]` | yes | yes | Fastest. No copy at the call boundary. |
| `String` | yes | yes | UTF-8 encoded to bytes once. |
| `ByteBuffer` (NIO) | yes | yes | For callers already holding a `ByteBuffer`. |
| `Encodable` | — | `validate(encoding:)` | JSON-encoded via `JSONEncoder`, then validated. |

### Two-phase validation

Validation runs a fast pass first; only if that pass finds a problem does it
run a second pass that collects every violation with its JSON-Pointer location.
Valid instances — the common case — pay only the fast pass.

### Conformance

`DXJSONSchema` passes 100% of the mainline Draft 2020-12 official test suite
(1295/1295, empty skiplist). The keyword surface is complete: `type`, `const`,
`enum`, all numeric and string and array and object assertions, `pattern`,
`allOf`/`anyOf`/`oneOf`/`not`, `if`/`then`/`else`, `properties`/
`patternProperties`/`additionalProperties`/`propertyNames`, `prefixItems`/
`items`/`contains`, `dependentRequired`/`dependentSchemas`,
`unevaluatedItems`/`unevaluatedProperties`, `$ref`/`$dynamicRef`/`$anchor`/
`$dynamicAnchor`/`$id`/`$defs`, and `$vocabulary` dialect gating.

### `format` is annotation-only by default

Per the specification, `format` is an annotation by default — it does not
reject malformed values unless the format-assertion vocabulary is enabled.
`DXJSONSchema` follows this default. Opt into assertion explicitly:

```swift
let strict = try JSONSchema.compile(schemaText, formats: .assertion)
```

Assertion mode validates the common formats (`date-time`, `date`, `time`,
`duration`, `email`, `hostname`, `ipv4`, `ipv6`, `uri`, `uri-reference`,
`uuid`, `json-pointer`, `relative-json-pointer`, `regex`). It is intentionally
coarse on the hardest formats and does not assert `idn-email`, `idn-hostname`,
`iri`, `iri-reference`, or `uri-template` (they pass as annotations). Use the
bytes path and your own check when you need RFC-exact validation of those.

### References and remote documents

Local references (`$ref` to `#`, `#/json/pointer`, `#anchor`, `$id`-relative)
resolve at compile time. For `$ref` across documents, provide the referenced
documents explicitly as `SchemaResource` values — there is no network I/O:

```swift
let resources = [
    SchemaResource(uri: "https://example.com/address", json: addressSchemaBytes),
]
let schema = try JSONSchema.compile(orderSchemaBytes, resources: resources)
```

To validate that a schema document is itself a well-formed Draft 2020-12
schema, compile it against the embedded meta-schema:

```swift
let metaValidator = try JSONSchema.compile(
    Array(#"{"$ref":"https://json-schema.org/draft/2020-12/schema"}"#.utf8),
    resources: JSONSchema.draft2020MetaSchemaResources
)
let ok = metaValidator.validate(candidateSchemaBytes).isValid
```

## Usage patterns

### Single schema

Compile at startup, validate per request.

```swift
struct Validators {
    let order: JSONSchema
    init() throws {
        order = try JSONSchema.compile(orderSchemaText)
    }
}

// per request, on any task:
let result = validators.order.validate(requestBody)   // requestBody: [UInt8]
```

### Registry of many schemas, hot-swappable

`SchemaRegistry` maps an opaque `String` type to one or more schema revisions.
Validating by type accepts an instance if **any** revision accepts it
(OR-across-revisions). Bulk updates are atomic: schemas are compiled and
structure-validated against the meta-schema outside the lock, then published
in a single store, so in-flight validations never observe a partial update.
Reads are lock-free.

```swift
let registry = SchemaRegistry()

try registry.apply([
    SchemaEnvelope(type: "order.v1", schema: orderV1Bytes),
    SchemaEnvelope(type: "product.v1", schema: productV1Bytes),
])

let result = registry.validate(requestBody, type: "order.v1")
```

`apply` replaces the whole registry atomically; `merge` upserts per type.
Both throw `JSONSchemaError.invalidSchemaType` for an empty type and
`JSONSchemaError.invalidSchemaStructure(type:)` for a document that is not a
valid Draft 2020-12 schema — so an invalid schema can never be registered.

Zero-downtime migration: register the old and new revisions of a type together
(both accept during the transition), then apply only the new revision once
producers have migrated.

```swift
try registry.merge([
    SchemaEnvelope(type: "order", schema: orderV1Bytes),
    SchemaEnvelope(type: "order", schema: orderV2Bytes),   // OR-accept both
])
```

### Parallel batch verification

`verify(batch:)` spreads work across all cores and returns two buckets —
succeeded and failed — with each entry tagged by a caller-supplied identifier,
so a single malformed payload cannot fail the batch and every result stays
attributable among otherwise indistinguishable byte buffers.

```swift
let requests = orders.map { order in
    VerificationRequest(id: order.id, type: "order.v1", payload: order.body)
}
let report = await registry.verify(batch: requests)

print("\(report.successCount) ok, \(report.failureCount) failed")
for failure in report.failed {
    log(id: failure.id, result: failure.result)
}
```

Use a cheap unique `ID` (e.g. `Int`) for the highest throughput on tens of
millions of payloads; `String`/`UUID` also work.

## Operations and overloads

| Operation | Forms | Returns |
|-----------|-------|---------|
| `JSONSchema.compile` | `[UInt8]`, `String`, `ByteBuffer`; optional `formats:` and `resources:` | `JSONSchema` (throws `JSONSchemaError`) |
| `JSONSchema.validate` | `[UInt8]`, `String`, `ByteBuffer`, `encoding: Encodable` | `SchemaValidationResult` |
| `JSONSchema.validate(batch:)` | `Sequence` of `[UInt8]` | `[SchemaValidationResult]` |
| `SchemaRegistry.apply` / `merge` | `[SchemaEnvelope]` | throws `JSONSchemaError` |
| `SchemaRegistry.validate` | `[UInt8]`, `String`, `ByteBuffer`, `encoding:`; with `type:` | `SchemaValidationResult` |
| `SchemaRegistry.verify(batch:)` | `[VerificationRequest<ID>]` | `VerificationReport<ID>` (async) |
| `SchemaRegistry.registeredTypes` / `revisionCount(ofType:)` / `generation` | — | introspection |

## Error handling

### `JSONSchemaError` — compile and registration time

One typed enum, surfaced by every throwing API. Conforms to `Error`,
`Sendable`, `Equatable`, `CustomStringConvertible`.

| Case | Fires when |
|------|-----------|
| `schemaNotValidJSON(byteOffset:hint:)` | The schema text is not valid JSON. |
| `schemaNotObjectOrBoolean(keywordLocation:)` | A schema (or subschema) is not an object or boolean. |
| `keywordValueMalformed(keyword:keywordLocation:expected:)` | A keyword's value has the wrong shape (e.g. `required` is not an array of strings). |
| `unsupportedKeyword(keyword:keywordLocation:)` | A keyword is not supported. |
| `patternNotValid(keywordLocation:pattern:)` | A `pattern`/`patternProperties` regex does not compile. |
| `unresolvedReference(reference:keywordLocation:)` | A `$ref`/`$dynamicRef` target could not be resolved (e.g. a missing remote document). |
| `invalidSchemaType` | A registry envelope has an empty type string. |
| `invalidSchemaStructure(type:)` | A registry schema is not a valid Draft 2020-12 schema. |
| `unknownRequiredVocabulary(uri:)` | A meta-schema declares a required vocabulary that is not known. |

### `SchemaValidationResult` — validation time

`validate` never throws; it returns one of:

| Case | Meaning |
|------|---------|
| `valid` | The instance satisfies the schema. |
| `invalid([SchemaViolation])` | The instance failed; each violation carries `instanceLocation`, `keywordLocation`, `keyword`, and `message`. |
| `instanceNotValidJSON(byteOffset:hint:)` | The instance bytes are not valid JSON. |
| `schemaNotRegistered(type:)` | (Registry only) no schema is registered for the requested type. |

`result.isValid` and `result.violations` are convenience accessors.

## Performance

Reference measurements on a Xeon Gold 6148, release build with
cross-module optimization, single localhost process:

| Mode | Throughput |
|------|-----------|
| Single-thread, compile-once + validate (small object) | ~50,000 validations/sec |
| Parallel batch, distinct payloads, ~16 cores | ~525,000 validations/sec |

The single-thread path is at parity with the fastest Go validator
(santhosh-tekuri/jsonschema v6) on the same workload. Throughput is
allocation-bound, so it scales well across cores once payloads are distinct
buffers. Absolute numbers depend on hardware and schema/instance shape — run
the benchmark on your own hardware (below) for a number you can trust.

### Picking an input form

- **`[UInt8]`** is the fastest path and the universal escape hatch. Pass it on
  the hot path; it incurs no copy at the call boundary.
- **`String`** costs one UTF-8 encode per call. Fine for ergonomics.
- **`Encodable` (`validate(encoding:)`)** costs a `JSONEncoder` pass. Use it
  when you are validating a model you already have in memory.
- For verifying many payloads concurrently, use **`verify(batch:)`** with
  distinct payload buffers; shared buffers across threads incur reference-count
  contention and do not scale.

## Performance testing

The benchmark lives in the standalone `Benchmarks` package as the
`JSONSchemaBenchmark` product. It reports parse+validate throughput across
N = 1 … 1,000,000 for several modes (precompiled, one-shot, registry, parallel
batch with shared and distinct payloads).

```bash
swift run -c release --package-path Benchmarks JSONSchemaBenchmark
```

Each line is tagged `[JSONSCHEMA PERF SWIFT]`. For a clean single-thread
number, pin the process to one core and remove other load from the box:

```bash
taskset -c 0 swift run -c release --package-path Benchmarks JSONSchemaBenchmark
```

## Memory

The validator does not leak under sustained or concurrent load. Every
`validate`/`apply` fully reclaims its working memory (the parsed instance tree
is freed; sliced strings release the source buffer; the registry releases the
superseded snapshot). Steady-state resident memory for a precompiled
validate loop is on the order of tens of MB and does not grow — it plateaus
and stays. This has been verified with sustained RSS soaks (millions of
validations, flat RSS) and with heaptrack (leaked allocations constant
regardless of iteration count). On process exit the OS reclaims everything.

The compiled `JSONSchema` and the registry's current snapshot are the only
long-lived allocations — another reason to compile once and reuse.

The benchmark binary exposes soak modes for verifying this on your hardware
(each prints `VmRSS` over time; watch for a plateau, not linear growth):

```bash
# single-thread validate soak (RSS must stay flat)
DX_LEAK_SOAK=5000000        swift run -c release --package-path Benchmarks JSONSchemaBenchmark
# concurrent validate soak (N worker threads)
DX_CONCURRENT_SOAK=16       swift run -c release --package-path Benchmarks JSONSchemaBenchmark
# registry hot-swap churn (RCU snapshot reclamation)
DX_REGISTRY_CHURN=40000     swift run -c release --package-path Benchmarks JSONSchemaBenchmark
# concurrent registry: readers + a writer churning snapshots
DX_CONCURRENT_REGISTRY=16   swift run -c release --package-path Benchmarks JSONSchemaBenchmark
```

## Hints

- **Compile once, share the value.** `JSONSchema` is `Sendable` and immutable;
  do not recompile per request.
- **Pass `[UInt8]` on the hot path.** Reach for `String`/`Encodable` for
  ergonomics, knowing each adds one conversion.
- **Use distinct payload buffers for parallel verification.** Sharing one
  buffer across threads serialises on its reference count.
- **`format` does not assert by default.** Opt into `.assertion` only when you
  need it, and know it is coarse on the hardest formats.
- **Register multiple revisions per type for zero-downtime migration.** A type
  validates if any of its revisions accepts the instance.
- **Invalid schemas cannot be registered.** `apply`/`merge` structure-validate
  every schema against the meta-schema before publishing.
