# attachmentStreamV1

`ContentCryptoSuite.attachmentStreamV1` registers the additive descriptor
`haven.attachment.stream.v1` through an extension in `Crypto/AttachmentStreamV1.swift`.
Use `AttachmentStreamV1` / `AttachmentStreamSealer` for its chunk API. The existing
whole-content `ContentCryptoEnvelopeUtility` and its suite selection remain
unchanged and do not accept this direct-symmetric profile.

This suite provides ChaCha20-Poly1305 chunk encryption with one fresh 256-bit
content key for each stream. It does not distribute that key, authenticate a
sender identity, or claim forward secrecy. Keep the key separate from ciphertext.
The header and chunks are Codable; the result containing the secret is not.

```swift
let sealed = try AttachmentStreamV1.seal(plaintext: bytes, chunkSize: 64 * 1024)
let clear = try AttachmentStreamV1.open(stream: sealed.stream, using: sealed.contentKey)
```

The `chunkSize` parameter defaults to `AttachmentStreamV1.defaultChunkSize`:
65,536 bytes (64 KiB) of plaintext. This is an engineering choice to bound each
AEAD operation while amortizing its 28-byte nonce/tag overhead; no throughput or
latency advantage has been measured. Valid sizes are 1 through `UInt32.max`
bytes per chunk. The format has no separate total byte-length cap; indices are
UInt64 and the last index is reserved for the terminal frame if reached.
Platform allocation and available memory still limit the convenience APIs.

For incremental encryption, create one `AttachmentStreamSealer(chunkSize:)`,
read its `header` and `contentKey`, call `sealChunk(_:)` with full chunks followed
by at most one nonempty short chunk, then call `finish()` exactly once. The
sealer retains no previous chunks. It is sequential and not Sendable; callers
must not access it concurrently. A fresh instance always generates a fresh key.
There is deliberately no supplied-key constructor or counter-reset API.
Restarting encryption creates a new stream and key; replaying stored ciphertext
does not call the sealer again. A crypto failure permanently closes the sealer.

`open(header:chunks:using:)` accepts a single-pass Sequence, verifies it in order,
and buffers plaintext privately until authenticated EOF and input exhaustion.
It returns no partial plaintext on failure. Memory-bounded transactional output
to a file or other sink is future integration work; this API does not provide it.
The in-memory `seal(plaintext:)` convenience also retains the ciphertext array.

## Cryptographic framing

Header: `suiteID` (exact value above), `version` (1), `chunkSize` (positive Int
validated within UInt32). Chunk: `index` (UInt64), `isFinal` (Bool),
`combinedCiphertext` (Data, base64 in JSON).

Nonce derivation is **deterministic from the content key and chunk index**:

```text
prefix = first 4 bytes of HMAC-SHA256(contentKey, UTF8("HAVEN.AttachmentStream.v1.nonce"))
nonce  = prefix || UInt64BE(index)
```

Indices start at zero and never repeat under a sealer's key. The 64-bit suffix
makes nonces distinct within that stream without relying on truncated-HMAC
collision resistance. Fresh keys prevent restarting at zero under the same key.
The library's combined representation also carries this 12-byte nonce; `open`
checks it against the derivation and authenticates the full frame.
Nonce uniqueness under a fixed key is required by
[RFC 5116 §3.1](https://www.rfc-editor.org/rfc/rfc5116.html#section-3.1).
ChaCha20-Poly1305 uses a 256-bit key, 96-bit nonce and 128-bit tag as specified in
[RFC 8439 §2.8](https://www.rfc-editor.org/rfc/rfc8439.html#section-2.8).

Every chunk uses the same content key and this binary additional authenticated
data (AAD), without JSON canonicalization:

```text
UTF8("haven.attachment.stream.v1") || 0x00
    || UInt32BE(version) || UInt32BE(chunkSize)
    || UInt64BE(index) || UInt8(isFinal ? 1 : 0)
```

Data chunks encrypt 1…chunkSize plaintext bytes. Exactly one empty authenticated
terminal chunk follows, with `isFinal = true` and index equal to the number of
data chunks. Even an empty stream contains this terminal chunk. Short data
chunks may appear only immediately before the terminal chunk. No chunk may
follow the terminal chunk. All frames contain `nonce || ciphertext || tag`.

`open` rejects unsupported descriptors, invalid sizes or key lengths, missing or
repeated indices, reordering, invalid lengths, altered nonces/ciphertext/tags,
data after a short chunk, absent EOF and any data after EOF. The terminal flag
and index are authenticated: renumbering a suffix or converting a data frame
into EOF cannot produce an accepted shorter stream without the key.
Substituting chunks from a different stream fails under the recipient's key.
Replaying an entire valid stream with its correct key is outside this suite's
replay policy; binding to a specific message belongs to the enclosing protocol.

This framing is cryptographic metadata, not an attachment manifest. Size, chunk
count and boundaries are visible. Message binding, secure key distribution,
transport, grants, retention and client/MCP integration are outside this change.

## Verification boundary

`Tests/CellBaseTests/AttachmentStreamV1Tests.swift` covers round trips, edge sizes,
tampering, missing/reordered/repeated chunks, missing EOF, wrong keys, header
authentication, nonce derivation, serialization and the incremental API.
Actual commands, outputs and existing-suite regression results are recorded in
`../_s5-rundtur-20260909/VEDLEGG_KRYPTO_RAPPORT.md` at the HAVEN workspace level.
These tests do not constitute an independent cryptographic review or a
measurement of large-file memory use, throughput, Linux or network behavior.
