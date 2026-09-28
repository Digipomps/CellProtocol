# Peer channel v2

Status: unreleased profile `org.haven.bridge-peer-channel.v2`. This replaces the
v1 peer handshake; no negotiation, v1 fallback, or plaintext application mode
exists. WebSocket channel authentication is a separate, unchanged profile.

## Boundary and authority

The accepted invitation identifies the endpoint scope, not a trusted person.
`ScannerPeerTransport` owns an immutable physical peer, MCSession, setup instance
and role. Discovery cannot change that binding. MCSession continues to require
its own encryption. The following authenticated key exchange and record layer
protect the bytes end to end even if an intermediary terminates that outer
transport and forwards the handshake unchanged.

The existing `BridgeChannelSession` verifies each identity signature, reserves
admission and quotas, rechecks policy, and activates the channel. Local identity
signatures come only from the local owner's vault. No identity private key is
transmitted or used as an encryption key. Admission proves key control; it does
not replace Resolver, Agreement, Grant, origin-proof or Cell owner authorization.

## Message flow

I means initiator, R means responder. Plaintext below means before this record
layer; the enclosing MCSession still requires encryption.

1. I → R: plaintext `channelAuthPeerHello` containing I's hello.
2. R → I: plaintext `channelAuthPeerChallenge`, containing R's hello and R's
   identity signature over the responder signing challenge.
3. I verifies R's signature, signs its own challenge, derives record keys and
   sends plaintext `channelAuthPeerProof` with I's identity signature.
4. R verifies I's signature, derives record keys and sends
   `channelAuthPeerAccepted` as **R's record zero**. R has no active Base yet.
5. I opens record zero, validates the acknowledgement, sends its acknowledgement
   as **I's record zero**, then activates its session and creates its Base.
   R opens I's record zero, validates it, then activates and creates its Base.
6. Every subsequent message, including commands, responses, signing RPCs, flows
   and discovery-token payloads, is an authenticated encrypted record. Each side
   must receive valid key confirmation before activation and `peerReady`.

An acknowledgement retains the existing session ID, verifier generation and
signer-specific transcript digest. The first opened record must be the expected
acknowledgement, never an application message. A missing or held acknowledgement
does not authorize application dispatch. Authentication is one shot; unexpected
or repeated handshake messages close the channel. The existing handshake timeout,
expiry, revocation, retained-work and send budgets still apply.

## Hello and signed transcript

Each handshake/generation creates a fresh X25519 key pair with Crypto's secure
key generator. Hello has mandatory fields: `profile`, `endpoint`, `role`, public
`identity` descriptor, `ephemeralPublicKey` (32 bytes), `nonce` (32 bytes),
`generation` and `issuedAtMilliseconds`. Endpoint has `initiator`, `responder`,
`setupID`, and `domain`; identity has `uuid`, `algorithm`, `curve`, and `publicKey`.

Each `Transcript` contains both complete hellos in initiator/responder order plus
`signer`. Identity signing uses the existing `IdentitySigningChallenge`:
identity UUID/fingerprint, endpoint domain, resource = profile + colon + SHA256
hex of canonical transcript, action `openPeerBridgeChannel`, audience = profile
+ colon + SHA256 hex of canonical endpoint, verifier nonce, earliest hello time,
and existing challenge validity. Both ephemeral public keys are therefore bound
by **both** identity signatures, along with roles, identities, nonces, endpoint,
setup ID, generations, profile and time.

Canonical profile encoding is UTF-8 JSON from `BridgeChannelAuthentication.encode`
(sorted keys, no slash escaping, Data as base64). Peer envelopes must round-trip
exactly through this encoder; extra fields and alternate encodings are rejected.
`Challenge` is internal and not Codable; only the required wire messages are
public Codable types.

## Derivation

Compute X25519(local ephemeral private, remote ephemeral public) with Crypto.
Provider errors and an all-zero shared secret are fatal; the extra zero check ORs
all bytes without an early-exit comparison. There is no long-lived static ECDH
fallback. The ephemeral private key reference is discarded immediately after the
single derivation attempt; close/cancel discards it if derivation never happened.

Salt is SHA256 of the canonical JSON **array of the two entire signed
transcripts**, first `signer=initiator`, then `signer=responder`. The pair includes
all signed hello fields and signer roles; signature encodings are not KDF input.
For each direction separately, HKDF-SHA256 extract-and-expand produces 32 bytes:

- info = UTF8(profile + NUL + `key` + NUL + `initiator-to-responder`)
- info = UTF8(profile + NUL + `key` + NUL + `responder-to-initiator`)

Only the two symmetric keys remain in the connection-owned record layer; it is
not Codable and has no persistence or key-export API. Closing drops both keys.

## Binary record and AAD

The exact record layout is:

| Bytes | Meaning |
| --- | --- |
| 0–3 | ASCII `HPC2` |
| 4–39 | Sender's generation, the exact 36-byte UUID string from its signed hello |
| 40 | Direction: 0 for I→R, 1 for R→I |
| 41–48 | Unsigned 64-bit counter in big-endian order |
| 49 onward | ChaCha20-Poly1305 ciphertext, then the 16-byte authentication tag |

Nonce = four zero bytes followed by the eight counter bytes. Counter starts at
zero independently in each direction; the two directions have different keys.
AAD = UTF8(profile + NUL + `record` + NUL) followed by the complete 49-byte header.
The generation, direction, counter, magic/version and profile are authenticated.
No implicit JSON or host endianness enters nonce/AAD encoding.

Receivers require exactly the next counter and the expected generation and
direction. Duplicate, gap, reflection, previous-generation frame, tag failure,
truncation, empty frame, oversized frame or plaintext fallback closes the local
channel before dispatch; it cannot recover by receiving a later valid frame.
Counter `UInt64.max` is never used: the channel closes before increment can wrap.
Plaintext must contain 1 through 1,048,576 bytes; total overhead is 65 bytes.
The final wire size, including overhead, counts against existing send quotas.

Sealing and opening occur only at the immutable physical transport's byte
boundary. Seal plus the synchronous physical send share a lock, preserving
counter order under concurrent senders. Incoming callbacks enqueue synchronously;
record opening and handshake processing are serial. Cell operations can await
later responses without blocking record opening. The receive queue is bounded by
64 retained operations and 4 MiB, including wire bytes. Late callbacks captured
by a retired transport cannot select or close its replacement. A replay delivered
to a *current* transport is fatal, including during a new handshake.

## Claimed properties and limits

Subject to standard primitive assumptions, fresh secure randomness and correct
endpoint implementation, this profile provides mutual proof of the declared
identity keys bound to this end-to-end cryptographic channel, confidentiality
and integrity of each subsequent message, directional replay/reordering
rejection, and forward secrecy against later compromise of identity signing
keys after ephemeral/record secrets are discarded. An unmodified handshake
relay can still forward traffic but cannot derive the record keys or modify
accepted messages.

It does not hide public identities, hello fields, message sizes, timing or
connectivity; attest a person/device from discovery labels; defeat a compromised
endpoint, vault, random generator or live memory capture; prevent dropping,
delaying or denial of service; provide post-compromise recovery; or authorize
Cell operations. Discarding Swift/Crypto references is not a guarantee against
OS memory dumps or all residual copies. Independent cryptographic review and
host/deployment verification remain distinct from passing tests.

## Reuse and verification

Uses existing Crypto X25519, HKDF-SHA256 and ChaChaPoly; no new dependency or
cryptographic primitive. It follows `AttachmentStreamV1`'s fixed-width counter,
AAD, monotonic sequencing and terminal crypto-failure discipline. Its attachment
header, content-key ownership, EOF/short-chunk semantics and file nonce prefix do
not fit a bidirectional authenticated connection, so its sealer is not reused.
`ContentCryptoEnvelopeUtility` wraps content keys for recipients, including static
recipient key material; it is not this ephemeral mutual handshake. The general
content-suite catalog is unchanged because this is a transport protocol.

`BridgePeerRecordLayerTests` pins RFC 7748 agreement, independently computed HKDF
and complete v2 record vectors (both directions, counters zero and one), low-order
rejection, bounds, and counter exhaustion. `ScannerPeerAuthenticationTests`
exercises the controlled byte relay, attacks, actual Cell function, isolation,
quota accounting and N08/N09 regressions. The opt-in two-process Multipeer test
requires encrypted application-record counts in both directions on real MCSession.
This does not claim a physical three-device MITM or a production deployment.

Primitive references: [X25519, RFC 7748 §6.1](https://www.rfc-editor.org/rfc/rfc7748#section-6.1),
[HKDF, RFC 5869](https://www.rfc-editor.org/rfc/rfc5869),
[ChaCha20-Poly1305, RFC 8439 §2.8](https://www.rfc-editor.org/rfc/rfc8439#section-2.8).
