# UUID storage and text compatibility

CellProtocol stores UUID identifiers using `Foundation.UUID` on Apple platforms
and Linux. UUIDs retain all 128 bits. New identifiers still use Foundation's UUIDv4
generator; existing UUID versions, including v7, can be read without changing
their values or serialized representation.

## Representation and compatibility

`CellIdentifier` stores a UUID and a 32-bit mask recording lowercase hexadecimal
letters. This preserves the exact spelling of existing identifiers. Its measured
stride is 24 bytes on the tested 64-bit Apple toolchain; a bare `UUID` is 16 bytes.
The wrapper does not retain a heap String for a valid UUID. Legacy identifiers
such as names and `cell:///...` references use a String fallback. Malformed UUID
text also remains opaque text, as it was before this refactor.

Preserving spelling is necessary: existing resolver keys are case sensitive,
contract signatures include UUID text, persistence key derivation and
authenticated data include UUID text, and Apple keychain tags use that text.
Two differently cased spellings therefore remain distinct `CellIdentifier` keys,
even though their `.uuid` properties contain equal Foundation UUIDs. This change
does not alter authorization or silently normalize stored data.

`UUIDText` and `OptionalUUIDText` keep existing public String properties and
initializers source compatible while changing their stored representation.
Read-only properties remain externally read-only. Codable emits strings;
optional absent/null fields retain their prior behavior. `CodingKeyRepresentable`
keeps identifier-keyed dictionaries as JSON objects with the original text keys,
instead of the alternating key/value arrays produced by `[UUID: Value]`.
This dictionary conformance is available on all supported macOS/iOS versions
and Linux, and on tvOS 15.4 or later. Earlier tvOS versions retain scalar UUID
storage support; use the existing String-keyed export APIs for JSON objects there.

No persisted UUID conversion, renumbering, or wire version bump is required.
Consumers must rebuild against the updated package; this is not a binary ABI
compatibility promise.

## Lookup paths

The resolver's instance, name-to-ID, identity-to-cell, lifecycle, and facilitator
indices use `CellIdentifier`. The main Apple/Vapor vault UUID indices and
perspective reference dictionaries do too. Core cells and identities expose
`identifier`; wrapped fields expose `$field`. Use these stored values directly
inside hot paths:

```swift
var cells: [CellIdentifier: any Emit] = [:]
cells[cell.identifier] = cell
let found = cells[cell.identifier]
```

The String subscript remains available at compatibility boundaries. It parses a
UUID on every access; repeatedly calling `cell.uuid` also formats text. Parse
incoming text once and retain the identifier when performing repeated lookups.
`CellIdentifier` and `RuntimeCellID` explicitly implement equality and hashing
to avoid RawRepresentable's String-based defaults. Sorting by `<` intentionally
retains the old textual order and formats text; it is not the lookup path.

Dynamic entity data, endpoint names, URI/keypath strings, and existing public
String collections are not a universal UUID codec. They keep their existing
representation. This refactor does not introduce B-trees or distribute indices
over additional scaffolds.

## Verification

- `CellIdentifierStorageTests`: exact spelling, UUIDv4/v7, legacy references,
  case-sensitive keys, JSON dictionary shape, optional fields, mutation, and
  invalid JSON types, using a shared fixture on Apple and Linux.
- `CellIdentifierIntegrationTests`: resolver snapshots and isolation, cell and
  identity round trips, perspective references, legacy encrypted envelopes, and
  historical String-based contract signing payloads.
- Existing signed DeviceIngress golden fixtures and strict Vapor vault tests
  protect canonical wire bytes, signature verification, and persisted storage.
- `cellprotocol-swift-linux.yml` runs a dependency-free gate using the exact
  production identifier file. `vapor-identity-vault-linux.yml` builds all CellBase
  sources and the production Vapor vault, then runs the integration and wire
  tests. The latter deliberately excludes unrelated CellVapor sources requiring
  the private FileUtils-c dependency; it is not a full scaffold deployment test.

Local validation on 2026-09-23: 170 selected tests passed on macOS with the
Apple Swift 6.4 toolchain (147 CellBase tests and 23 commons tests). The Linux
integration gate passed all 41 tests on Swift 6.2.4, Ubuntu Noble, ARM64. This
includes the same eight storage tests, five new integration tests, three signed
wire fixture tests, and 25 existing strict vault tests. The standalone Linux
storage gate is additionally runnable without fetching any dependencies.

Repeated local Linux runs also exposed an intermittent XCTest teardown hang.
An LLDB backtrace placed it in `awaitUsingExpectation` /
`XCTestCase.performTearDownSequence`, with no test body running, matching the
stack in upstream [swift-corelibs-xctest #504](https://github.com/swiftlang/swift-corelibs-xctest/issues/504).
Treat a timeout as an incomplete run, not a pass. The reported passing run
executed every test; neither assertions nor production behavior were disabled.

## Memory and latency measurement

A local optimized microbenchmark on Apple Silicon used one million identifiers,
UInt64 values, pre-sized dictionaries, and 200,000 preconstructed random hit keys.
The new representation used about 64 MiB of incremental resident memory versus
125 MiB with UUID Strings. A bare Foundation UUID dictionary used about 48 MiB,
but does not preserve the existing case-sensitive textual identity contract.

One release run (`-O -whole-module-optimization`) measured approximately 150 ns
per hit for `CellIdentifier`, 167 ns for String, and 110 ns for bare UUID. These
are medians of batch averages, not p99 latency or end-to-end resolver timings.
Parsing, serialization, actor scheduling, misses, and concurrent workloads were
outside this measurement. The reproducible benefit established here is reduced
retained memory with binary hashing; production latency still needs workload
measurement.
