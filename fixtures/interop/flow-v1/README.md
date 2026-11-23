# Flow envelope fixtures v1

Pinned, synthetic test data for the signed flow envelope (`FlowEnvelope`,
`FlowEnvelopeSigner`, `FlowEnvelopeVerifier`, `FlowCanonicalEncoder`). They are
the reference a port (Kotlin first) checks its canonical bytes, hashes and
Ed25519 signatures against.

Every key here is a **public test key**: the seed is
`SHA-256("haven-interop-v1/<seed>")`, listed in `manifest.json`. Never use
them for anything else.

> **A JCS variant will follow.** These files pin today's canonical form
> (`canonicalization: foundation-sortedkeys-v1`). When signed objects move to
> RFC 8785 (JCS), the same cases get a `flow-v2` (JCS) set next to this one, and
> both are verified during the transition. See `Docs/JCS_TRANSITION_PLAN.md`.
> Do not regenerate these files to "fix" a byte difference: a difference means
> the canonical form changed, and that is a protocol change.

## Cases

| Case | What it pins | Verdict |
|---|---|---|
| `flow.envelope.string.valid` | Text with `/`, quotes, backslash, newline, tab, æøå and emoji; mimetype; origin; signed provenance | `valid` |
| `flow.envelope.object.valid` | Object content with every simple `ValueType` (`number`, `integer` above 2^53, `float`, `bool`, `string`, `data`, `null`, `keyValue`, `list`, `object`, nested `flowElement`); `revisionLink`; `metadata` whose keys show the sort rule | `valid` |
| `flow.envelope.data.valid` | Base64 content, no provenance, no origin | `valid` |
| `flow.envelope.list.valid` | List content, no `properties`, custom `signatureKeyId`, `previousEnvelopeHash` = `envelopeHashHex` of the data case | `valid` |
| `flow.envelope.string.tampered` | Content changed after signing | `payloadHashMismatch` |
| `flow.envelope.string.wrong-key` | Signed by another key claiming the producer's uuid | `invalidProducerSignature` |

## What each case file holds

| Field | Meaning |
|---|---|
| `payloadCanonicalBase64` | `FlowCanonicalEncoder.canonicalData(for: payload)`: the FlowElement bytes |
| `payloadHashHex` | The envelope's `payloadHash`: lowercase hex SHA-256 of the payload bytes (not in the tampered case) |
| `canonicalBase64` | **The bytes the producer signature covers**: the envelope without `signature` and without `provenance` |
| `canonicalSHA256Hex` | SHA-256 of `canonicalBase64` |
| `signatureBase64` | Ed25519 (RFC 8032) signature over `canonicalBase64` |
| `provenanceCanonicalBase64` | The bytes the provenance signature covers: `{"originCell","originIdentity","payloadHash"}` |
| `provenanceSignatureBase64` | Ed25519 signature over `provenanceCanonicalBase64` (only with provenance) |
| `envelopeCanonicalBase64` | The whole envelope with `signature` and `provenance` |
| `envelopeHashHex` | `FlowHasher.envelopeHash`: SHA-256 of the envelope **with** provenance and **without** signature. This is what `previousEnvelopeHash` chains to |
| `envelope` | `envelopeCanonicalBase64` as JSON, for reading |
| `signer` | The producer's public key descriptor |
| `expect.signatureValid` | Whether `signatureBase64` verifies over `canonicalBase64` with `signer` |
| `expect.verdict` | What `FlowEnvelopeVerifier.verify` answers: `valid` or the `FlowIntegrityError` case name. Provenance is verified whenever it is present |

## How another implementation passes

1. Build each envelope from `envelope` with your own model.
2. Produce the payload bytes, signed bytes, provenance bytes and full envelope
   bytes, and compare **byte for byte** with the files.
3. Verify the committed signatures and compare with `expect`.
4. Sign `canonicalBase64` with the producer seed: Ed25519 is deterministic, so
   your signature must equal `signatureBase64` (Apple CryptoKit is randomized;
   there, only verification is compared).

## The canonical rule (where implementations go wrong)

`FlowCanonicalEncoder` builds a `[String: Any]` tree and writes it with
`JSONSerialization.data(withJSONObject:options:[.sortedKeys])`:

- Every value is tagged: `{"$type":"<case>","value":<value>}`. `data`, `signData`
  and `signature` are standard base64 with padding; `null` is JSON `null`;
  `keyValue` is `{"key","value"?,"target"?}`.
- A FlowElement is `id`, `title`, `topic`, `content`, then `properties`
  (`type`, `mimetype`?, `contentType`?) and `origin` only when present.
  `hops` is **not** signed.
- Absent optionals are left out, never `null`.
- `/` is written as `\/`. Non-ASCII is raw UTF-8. No whitespace.
- Keys are sorted case-insensitively with digit runs compared as numbers:
  `alpha, item2, item10, Zulu` (see `metadata` in the object case). Not code-point order.
- Integers are written in full, also above 2^53 (`9007199254740993`). A port
  that reads JSON numbers as doubles loses the last digit.
- Doubles are written without a trailing `.0` (`1.0` is `1`, `1e21` is `1e+21`).
  **Darwin and Linux disagree on doubles that are not exact in binary:**
  Darwin writes `0.1` as `0.10000000000000001` (checked on macOS 27);
  swift-corelibs-foundation on Linux writes Swift's shortest form, `0.1`. The cases
  therefore only use exact values. This is one of the reasons for JCS.

## Regenerating

Only on purpose, on Linux, where swift-crypto's Ed25519 is deterministic:

```bash
HAVEN_WRITE_FLOW_FIXTURES=1 swift test --filter FlowEnvelopeFixturesV1Tests
```

`FlowEnvelopeFixturesV1Tests.testFlowEnvelopeFixturesV1MatchThisPlatform` runs
on every platform. It rebuilds and re-signs every case with CellBase and fails,
by case id, if any byte, hash or verdict differs from the committed files. The
Linux gate in `.github/workflows/cellprotocol-swift-linux.yml` runs it on every PR.
