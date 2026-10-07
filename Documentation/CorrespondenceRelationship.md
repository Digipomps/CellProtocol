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
Recipient signing fingerprints come from all admitted members plus the owner,
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
