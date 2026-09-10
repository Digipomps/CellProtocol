# FileCrypto envelope security and compatibility

New writes use version 2. ChaChaPoly authenticates the binary envelope header,
including the version, algorithms, credential ID, byte counts and user associated
data. The canonical authenticated header is the binary encoding with an empty
ciphertext field and a zero ciphertext-length field. AEAD verifies ciphertext;
the parser verifies the actual length and rejects extra envelope bytes.
Unknown versions fail closed. Changing a v2 envelope to v1 fails authentication.

Version 1 reads remain enabled for existing stored files. Their historical
headers cannot be authenticated retroactively. Trusted hosts can require v2 via
`FileCryptoReadLimits(allowLegacyEnvelope: false)` and migrate legacy files by
opening and sealing again. Older readers cannot open new v2 files; upgrade
readers before enabling new writers in a mixed-version deployment.

The default read policy caps encrypted input at 512 MiB and plaintext at 256 MiB.
Trusted Swift callers can explicitly choose larger limits. The policy is not a
field in the wire request, so remote callers cannot raise it. Decompression checks
the declared length and host ceiling before appending output, and rejects a
stalled decoder. The limit bounds each operation, not aggregate concurrent work;
hosts still control ingress payload limits and concurrency.

Apple Compression can consume some trailing compressed bytes internally. The
implementation does not claim canonical compressed-stream encoding. Such bytes
are authenticated by AEAD. See Apple's documented end-of-input behavior:
[compression_stream_process](https://developer.apple.com/documentation/compression/compression_stream_process(_:_:)).

Regression tests cover integer overflow, every truncated envelope prefix,
slice-backed Data, explicit resource ceilings, expansion beyond declared size,
truncated compression, metadata tampering, downgrade attempts, unknown versions,
empty payload/AAD, and an independent synthetic v1 writer.
