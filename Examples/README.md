# SwiftDX Examples

Runnable usage demos for the libraries shipped in `swift-dx`. Each executable
target is a self-contained example you can compile and run against a local
NATS broker.

This is a **separate SwiftPM package** (not part of the main `swift-dx`
package) so the examples can take development-only dependencies and use
unsafe build flags without affecting downstream consumers of the libraries
themselves.

## Available Examples

### `JetStreamPublishAndFetch`

End-to-end demonstration of the `DXJetStream` library: connects to a NATS
broker, ensures a stream and a consumer, publishes a batch of messages,
fetches them back via a pull consumer, and acks. Mirrors the shape of a
small backend service that uses JetStream as its message bus.

### `JetStreamTestingPatterns`

Two patterns side by side: a unit-test-style approach using a mock client
that conforms to `JetStreamClient`, and a real-broker integration shape.
Shows how to keep service code testable without standing up a NATS broker
for every CI run.

## Running

You need a running NATS broker on `localhost:4222`. The simplest way is the
docker-compose cluster bundled in this repository:

```sh
cd ../Tooling/Compose
docker compose --profile nats up -d
cd ../../Examples
```

Then run any example:

```sh
swift run JetStreamPublishAndFetch
swift run JetStreamTestingPatterns
```

The `JetStreamTestingPatterns` example does not require a broker for its
mock-client demonstration; it will skip the integration portion gracefully
if no broker is reachable.

## Layout

```
Examples/
├── Package.swift                       # separate SwiftPM package
└── Sources/
    └── JetStream/
        ├── PublishAndFetch/main.swift  # → JetStreamPublishAndFetch
        └── TestingPatterns/main.swift  # → JetStreamTestingPatterns
```

Each subfolder of `Sources/JetStream/` is an independent executable target.
New examples are added by creating a new subfolder and declaring a target
in `Package.swift`.
