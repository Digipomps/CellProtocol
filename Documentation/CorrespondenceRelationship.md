# Correspondence relationship commands

The host holds public participant descriptors. Participants keep separate private
vaults. Existing `.ownerApprovalRequired` local admission remains unchanged.

An owner creates a `CorrespondenceCell` once, records its generated UUID and
address, and preserves that UUID on restoration. A new relationship/clone needs
a new UUID and freshly signed contracts. Assign the address before signing;
changing a Cell UUID invalidates its cell-bound contracts. The Cell domain is
`correspondence`.

## Admission and renewal

Sign `CorrespondenceAgreementTemplates.withAttachments(owner:)`, with owner and
subject public signing and X25519 keys as signatories, state `signed`, and a
positive duration no longer than one year. Correspondence identities use their
UUID as display fallback and carry no identifying properties. Call
`Contract.signed(..., targetCellUUID: cell.uuid)` on the owner's machine. Bound
contracts sign `signaturePurpose = haven.contract.admission.v2`. Unbound local
contracts retain their existing signed payload; probe-era bound contracts without
the signed purpose cannot enter through external admission.

The invited identity submits the JSON Contract to SET `agreement.accept`.
Resolver permits only key-proven callers to submit this command; the handler
independently verifies the owner signature, Cell/domain/subject/time binding,
exact template grants, public encryption keys, subject key proof and conditions.
No submitter can manufacture admission authority. The Contract signing payload
contains the subject's signing fingerprint, while the top-level X25519 descriptor
is not itself signed. Admission therefore compares that installed descriptor to
the subject's X25519 key inside the signed Agreement signatories, and compares
the issuer/Agreement owner encryption key to the trusted Cell owner. A valid
signature alone does not prove an unchanged top-level encryption descriptor. `accepted` means the host
installed an already signed contract. The Swift API retains `.signed` for
compatibility, and does not mean the host signed it.

Renewal uses the same command and requires a later expiry. It replaces the
previous bound contract for the subject/Cell. Replaying the shorter old grant
cannot downgrade the renewal. Members and contracts do not accumulate.

## Revocation

On the owner machine call `ContractRevocation.signed(contract:owner:at:)` and
submit its JSON to SET `agreement.revoke`. The signature covers a distinct
purpose, Cell, domain, subject, Contract UUID, Agreement UUID, timestamp and
nonce. Responses are `revoked` or `rejected`. No owner key is needed on the host.

The authorization actor applies the command atomically and persists a subject
`revokedBefore` cutoff with contracts/members. Owner removal also records a
cutoff, even if admission is still pending. Admission checks the cutoff before
proof, after conditions and within installation. Later authorization checks it
again after security awaits. Previously signed contracts cannot restore access,
including after snapshot restoration. A fresh admission must be signed later
than the cutoff. Signed revocation replay is rejected. Revocation removes all
subject contracts and the member, and invalidates retained Flow subscriptions.
Already downloaded or transferred files remain outside the host's control.

## Text, attachments, history and Flow

Both parties use `sendMessage`, `readMessage`, `ackMessage`, `inbox` and the ten
`attachments.*` operations. For owner-originated attachments, `agreementID` is
the relationship Cell UUID; invited senders use their signed Agreement UUID.
The original context remains bound into the attachment manifest and envelope
AAD. Set `clientMessageID` to the attachment message UUID when sealing.
Recipient signing fingerprints come from currently active, nonrevoked contracts plus the owner,
rather than only the sender's Agreement. Each ordinary action still proves the
caller's key. Attachment byte chunks use the existing `AttachmentStreamV1`.

GET `state` (also `state(requester:)`) returns the member-only inbox history.
`flow(requester:)` publishes topic `haven.correspondence`. `message.stored`
includes `envelope` (outer metadata and encrypted inner envelope), so clients
can open it without polling. Other events include `message.read`,
`message.receipt`, `message.expired` and `attachments.*`. Events contain no
subject/body/file name/key or clear attachment content. The public purpose is
always the envelope purpose, not the message's private purpose. Nonmembers and
revoked/expired grants cannot subscribe or obtain history. Reconnection uses
history to recover missed events.

Live timers remove the whole message envelope without an inbox read; attachment
storage retains its existing independently scheduled expiry. Restoration
reschedules envelope timers when runtime bindings are installed. This is a live
runtime guarantee; an offline/stopped process cannot erase on schedule, and
backups/recipient exports are outside that guarantee. Hosts must persist Cell
snapshots through their ordinary persistence integration.

Local acceptance: `CorrespondenceRelationshipTests` uses three separate
E/H/I ephemeral vaults, Resolver-routed admission, both text directions,
1100037-byte copy attachments each way, retained Flow revocation, renewal,
replay and restored-state rejection. It does not establish a network handshake,
staging service, OS user-presence policy or production client behavior.

## Concurrent expiry

The mailbox locks sequence allocation, insertion, receipt updates, removals and
serialization snapshots. Automatic expiry captures the message sequence; it
cannot remove a later envelope that reuses the same message ID. Receipt updates
cannot resurrect an envelope already removed by expiry. The JSON dictionary
shape is unchanged. The focused local suite (53 tests) passed with Thread
Sanitizer, including 128 parallel sends while snapshotting across expiry and
reusing an expired ID before its original timer fires. This does not establish
that every runtime operation is safe under every concurrent schedule.

## Canonical descriptors and removal clocks

`Identity` decoding supplies `{}` for omitted properties. `Contract.signed`
therefore round-trips its public issuer/subject descriptors before returning a
wire document. Otherwise pinning canonical bytes before decoding produces a
different document after decoding, which DeviceIngress correctly rejects.

Each removal advances the subject cutoff even when a test clock is frozen, and
covers installed contract timestamps. A fresh local owner signature receives a
timestamp strictly beyond the previous cutoff; final actor installation can
still reject it after a concurrent removal. External admission and signed revocation allow five seconds of positive clock
skew. Owner removal and accepted signed revocation advance their cutoffs by the same five seconds and covers all
installed timestamps, so a pending, slightly future-dated contract cannot win
against removal. A new external signature after removal must be later than that
cutoff; clients whose clock is behind it wait or correct their clock. The larger
legacy verification allowance does not expand external admission. Signed bytes
are never rewritten in transit.

## Active encryption membership and attachment privacy

Membership refreshes carry the authorization actor's revision and a refresh
sequence; a stale refresh cannot overwrite a newer revision or later expiry
refresh. Sending and inbox access refresh lazily, including contract expiry.
Sending checks the fingerprint and exact recipient set again after its awaits,
in a synchronous authorization-actor effect, under the membership lock at insertion. Attachment preparation captures and
rechecks membership after storage preparation; a changed audience requires retry.
The legacy owner invitation convenience now creates an owner-signed contract;
adding a UUID alone no longer changes encryption membership. It requires the
owner's signing key and the subject's local vault proof.

Attachment request encoding removes the filename. Host copy plans and returned
metadata use an empty name; clients retain the original filename in their signed,
encrypted inner manifest. The durable attachment index excludes local source
records, filenames and reference URLs. Local sender sources remain in memory and
must be registered again after restart. Peer `attachments.probe` refuses arbitrary
source discovery with a fixed error code. Storage root paths are runtime
provisioning and are excluded from Cell snapshots. After decoding a relationship,
the host must call `configureAttachmentStorage(root:requester:)` with its trusted
root before attachment actions; this rebinds existing sender components and
recovers durable copy chunks. Unprovisioned attachment access fails closed. Peer preparation accepts encrypted chunk import only (`sourceID` must be absent).
Local source APIs are for the
sender's own machine; they read plaintext and hold a stream sealer key and must
not be connected to a relationship server's peer ingress.

Peer errors use fixed codes instead of filesystem error descriptions. Purge
continues through independent entries after an erase failure and leaves failed
entries available for a later cleanup retry. Expiry still denies every access.

Persisted correspondence snapshots use `correspondenceContractSubject` for the
public Contract role descriptor, distinguishing it from a plaintext message
subject. Decode restores `subject` before Contract verification, without changing
signed bytes. Old `subject` snapshots continue to decode. Existing expiry tests
use their trusted fixture root and retain both positive chunk-presence and
post-expiry byte-deletion checks; the root is no longer taken from a snapshot.
