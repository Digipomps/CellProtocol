# Peer channel v3

Status: unreleased `org.haven.bridge-peer-channel.v3`. Peer v1/v2 and `HPC2`
are rejected; there is no negotiation or fallback. The WebSocket profile remains
`org.haven.bridge-channel.v1` (`openBridgeChannel`) and still requires its own
TLS/endpoint contract. Peer v3 is not a WS upgrade or a WS parser alternative.

This is a SIGMA-I based instantiation for local signing vaults, not a standard
Noise, IKE or TLS implementation. It protects identity fields from an intermediary
that terminates the outer transport but forwards the inner handshake unchanged.
An active initiator can learn the responder's identity in M2. An initiator reveals
its own identity only after verifying and locally accepting the responder.

## Authority and disclosure

The accepted invitation supplies the immutable local endpoint E with
`initiator`, `responder`, `setupID`, `domain`. Names are nonempty, at most 512
UTF-8 bytes; initiator and responder differ; setupID is an uppercase canonical
36-byte UUID. E is compared against decrypted authentication, never replaced
by a remote value. E and its hash are absent from the public hello.

`DisclosurePolicy` is mandatory on the peer gate constructor:

- `expectedIdentities` requires the configured domain and an exact descriptor
  (UUID, algorithm, curve, public key). Discovery names are not trusted pins.
- `anyProvenIdentity` explicitly permits first contact with any supported proven
  key. It does not protect initiator identity from an active accepted attacker.
- Both cases explicitly choose whether a responder may disclose to an as yet
  unauthenticated initiator. If false, a responder sends no authentication.

Scanner explicitly uses first-contact policy upon its accepted invitation.
Dynamic `recheckPolicy` is reapplied before signing/sending/activation. Local
owner revocation must close the corresponding gate; `limits.revoke` addresses
registered remote principals and is not a persistent revocation registry.

All signing comes from the local owner's vault, with public snapshot matching.
`BridgeIdentityVault` is forbidden as handshake signer. Public verification does
not ask a vault for authority. Channel admission proves control of the declared
key, not a person, discovery label, physical device, proximity or Cell permission.
Resolver, Agreement, Grant and origin-proof authorization remain required.

## Encoding and limits

C(x) is UTF-8 JSON from `BridgeChannelAuthentication.encode`: sorted keys,
without slash escaping, padded base64 Data. Every encoded object must survive
strict typed decode/re-encode byte-identically. Unknown/duplicate fields,
whitespace, alternative number/base64 encodings, trailing bytes and extra null
fields are rejected. The outer envelope has exactly `&string` (C(body) as a
string), `cid` (number zero) and `cmd`. It has no identity or transport metadata.
Maximum whole envelope is 16384 bytes; M1 is additionally bounded to 2048.

Hello has exactly `profile`, `role`, `ephemeralPublicKey`, `nonce`, `generation`,
`issuedAtMilliseconds`. DH public and nonce are 32 bytes; generation is a
canonical uppercase UUID, different from the local generation. Time is a
nonnegative Int64 in milliseconds. On receipt require
`nowMS - 10000 < issued <= nowMS + 5000` without integer wrap. The original
10-second monotonic handshake deadline is never extended; completion must also
precede `min(tI,tR)+30000` wall milliseconds. Active lifetime is at most
`min(tI,tR)+300000` with wall and monotonic checks.

Identity has exactly `uuid`, `algorithm`, `curve`, `publicKey`. EdDSA/Curve25519
uses a 32-byte public key and 64-byte signature; ECDSA/P256 uses a validated
33-byte compressed or 65-byte X9.63 public key and valid DER signature of at most
256 bytes. Transcripts bind the representation actually sent. Quota accounting
separately canonicalizes the signing key, independent of UUID and domain (N17).

`Pad_N(x) = U32(len(C(x))) || C(x) || zeroBytes(N-4-len(C(x)))`.
Auth uses N=8192; Finished uses N=1024. Length must be 1...N-4 and all padding
zero. Sealed fields are therefore exactly 8208 and 1040 bytes respectively,
including the full 16-byte tag. There is no compression or variable padding.
Actual JSON/base64/wire overhead counts toward the send budget.

## Transcripts and key schedule

U means UTF-8, integers are unsigned big endian, LP(b)=U32(len(b))||b.
`F(label,b1,...,bn)=LP(U(P))||LP(U(label))||U32(n)||LP(b1)||...||LP(bn)`.
H is SHA-256; hex is lowercase. Wj is the entire canonical envelope, ciphertext
and tag included. No digest depends on a future message:

```
T1 = H(F("wire-1", W1))
T0 = H(F("clear-2", T1, C(H_R)))
T2 = H(F("wire-2", T0, W2))
T3 = H(F("wire-3", T2, W3))
T4 = H(F("wire-4", T3, W4))
T5 = H(F("wire-5", T4, W5))
Z = X25519(local fresh ephemeral private, remote ephemeral public)
PRK = HKDF-Extract-SHA256(salt=T0, IKM=Z)
K(label,d,context) = HKDF-Expand-SHA256(PRK,
    F("kdf", U(label), U(d), context, U16(32)), 32)
```

Each key is separately derived for `initiator-to-responder` and
`responder-to-initiator`. Labels/context: `handshake-key`/T0 (Khs),
`identity-mac-key`/T0 (Kid), `finished-key`/T3 (Kfin),
`application-key`/T5 (Kapp). Provider errors and all-zero Z are fatal; the
additional zero check ORs every byte. DH is attempted once; its private reference
is dropped on success/failure/cancel. PRK and handshake key material are dropped
at completion or terminal failure. Only Kapp remains in the record layer.
There is no secret serialization, export, persistence, static DH, PSK, resumption,
early data, rekey or retry in one operation.

Handshake nonce is four zero bytes plus U64(counter); it is implicit. M2/M3
use counter 0 and M4/M5 counter 1 under their respective directional Khs.
AAD is `F("handshake-aead", U(step), previousTranscript)`, with previous
transcripts T0, T2, T3, T4 respectively. Sealed = ciphertext||tag. No fallback
key is tried after failure. Every outgoing message is sealed at most once.

## Signatures, identity MAC and five messages

```
D_R = {profile:P, signer:"responder", helloDigest:hex(T0), endpoint:E, identity:Id_R}
D_I = {profile:P, signer:"initiator", helloDigest:hex(T0), previousDigest:hex(T2),
       endpoint:E, identity:Id_I, peerIdentity:Id_R}
d_s = hex(H(C(D_s)))
```

The operation reconstructs `IdentitySigningChallenge`: existing type/version 1,
purpose `identity-origin-proof`, own identity UUID/fingerprint, E.domain,
resource P+":"+d_s, action `openPeerBridgeChannel`, audience P+":"+hex(H(C(E))),
verifier's nonce, Date(min(tI,tR)/1000), validity 30 seconds. Signing bytes are
C(challenge), also without slash escaping. Proof is `{sessionID:E.setupID,
generation:verifierHello.generation,signature}`. No incoming signingData is used.

Core_s is `{endpoint:E,identity:Id_s,proof:Proof_s}`. Auth_s has those fields plus
`identityMAC = HMAC-SHA256(Kid[s], F("identity-mac",U(role),context,C(Core_s)))`,
where context is T0 for R and T2 for I. MAC comparison uses the provider's
constant-time verification. MAC and signature must both verify before key quota
or principal registration. Policy acceptance precedes initiator signing.

| Step | Direction / command | Body |
|---|---|---|
| M1 | I→R `channelAuthPeerV3Hello` | H_I |
| M2 | R→I `channelAuthPeerV3ResponderAuth` | `{hello:H_R,sealed:Seal(Pad_8192(Auth_R))}` |
| M3 | I→R `channelAuthPeerV3InitiatorAuth` | `{profile:P,sealed:Seal(Pad_8192(Auth_I))}` |
| M4 | R→I `channelAuthPeerV3ResponderFinished` | `{profile:P,sealed:Seal(Pad_1024(Finished_R))}` |
| M5 | I→R `channelAuthPeerV3InitiatorFinished` | `{profile:P,sealed:Seal(Pad_1024(Finished_I))}` |

Ack_R is `{sessionID:E.setupID,generation:H_R.generation,transcriptDigest:d_I}`;
Ack_I uses H_I.generation and d_R. Finished is `{ack,verifyData}` with
`verify_R=HMAC(Kfin[R→I],F("finished",U("4"),T3,C(Ack_R)))` and
`verify_I=HMAC(Kfin[I→R],F("finished",U("5"),T4,C(Ack_I)))`.

R has no remote principal after M1/M2. I verifies R in M2; R verifies I in M3.
I activates only after receiving valid M4 and successfully submitting M5;
R activates only after receiving valid M5. Kapp derives from T5. Neither factory
runs before local proof plus Finished validation. I does not yet know that R
received M5. Both signatures bind both hello/DH values; only I's signature
includes both identities. Finished and Kapp bind the complete exchange.

Explicit states reserve processing before awaits. Only the next message is
accepted. Duplicates, skipped/reordered steps, old profiles, WS envelopes,
plaintext app data and authentication after activation are terminal. Every
vault/policy/send/factory continuation rechecks the captured gate and session.
Noncooperative work retains its work reservation until it returns. Adapter
send admission is synchronized with gate close and direct session revocation;
a physical submission that already won admission cannot be recalled.

Handshake reservations are retained until authenticated progress; I's M5 remains
reserved until authenticated Kapp traffic or close. This does not prove OS buffer
release or honest remote processing. [Physical flow control](PeerPhysicalFlowControl.md) specifies the bounded receipt
window and per-peer MC retirement added by N14/N15/N18, including the remaining
pre-callback OS reassembly boundary.

## Application records

`HPC3 || U(senderGeneration) || directionByte || U64(counter)` is the 49-byte
header. Direction is 0 for I→R, 1 for R→I. AAD is
`U(P+NUL+"record"+NUL)||header`; nonce is four zero bytes plus U64(counter).
Wire is header||ChaCha20-Poly1305(Kapp,nonce,plaintext,AAD), with 16-byte tag.
Counters start at 0 after Finished; `UInt64.max` is never used. Plaintext is
1...1048576 bytes; overhead is 65. Exactly next counter/generation/direction
is required. Replay, gap, reflection, wrong magic, tag, length or plaintext is
terminal. Inner peerGeneration/session/principal checks remain mandatory.
All app commands, responses, flows, NI data and origin-signing RPCs use this path.
Record plaintext now contains the mandatory binary application/receipt wrapper
described in [Physical flow control](PeerPhysicalFlowControl.md); the 1 MiB limit
includes that wrapper.

## Evidence and limits

`BridgePeerV3Tests`, `BridgePeerRecordLayerTests` and
`ScannerPeerAuthenticationTests` exercise the construction, wire boundary and
lifecycle. `Tests/CellBaseTests/Fixtures/PeerV3/reference.py` independently
calculates vectors using Python stdlib and already installed OpenSSL; it never
imports production outputs. Fixed-signature vaults accept only their exact
synthetic challenge and verify their fixture signature. Live signing is tested
separately: CryptoKit may randomize even Ed25519 signatures, so live ciphertext
is not required to equal deterministic reference ciphertext.

Identity confidentiality here excludes traffic sizes/timing, physical/discovery
metadata, an accepted active peer, compromised endpoints/vaults/randomness or
live memory. An active initiator learns R after M2; an active responder with an
accepted identity learns I after M3. Forward secrecy assumes fresh DH and erased
secrets; dropping Swift references does not attest zeroization of OS copies.
No general anonymity, DoS, post-compromise recovery, deniability, formal security
proof, independent crypto audit or production approval is claimed.

[Scanner admission and ordering](ScannerAdmissionAndOrdering.md) describes the
N10/N11/N16 consumer, invitation and pre-authentication budgets.
[EntityScanner consumer security](ScannerConsumerSecurity.md) specifies N13/N20
work leases, pending records and contact-proof validation.
[Scanner NI binding](ScannerNearbyInteraction.md) specifies the N12 per-peer
sessions, immutable tokens and callback retirement. See the physical flow-control document
for measured resource bounds and the remaining MC reassembly limitation.
[Shared bridge lifecycle rules](BridgeLifecycle.md) describe the N23–N26 response,
mux-send, factory and signing protections. A controlled inner-wire relay is not a three-process MC MITM or a radio/NI device test.

References: [SIGMA](https://iacr.org/cryptodb/archive/2003/CRYPTO/1495/1495.pdf),
[RFC 7748](https://www.rfc-editor.org/rfc/rfc7748),
[RFC 5869](https://www.rfc-editor.org/rfc/rfc5869),
[RFC 8439](https://www.rfc-editor.org/rfc/rfc8439),
[TLS Finished comparison](https://www.rfc-editor.org/rfc/rfc8446#section-4.4.4).
