# Correspondence attachments (candidate, September 2026)

Purpose: a recipient can use the intended material while the sender retains a
revocable, message-scoped delivery until an explicit ownership transfer.
Acceptance by the owner, actual installer/budget delivery and deployment are
separate from the local implementation tests.

## Authority and storage

`CorrespondenceEnvelopeUtility` signs an optional attachment descriptor inside
the encrypted inner envelope. The descriptor binds attachment ID, message ID,
originating Agreement UUID, relationship Cell UUID, sender, metadata, mode,
reference and (for streamed modes) the AttachmentStreamV1 header/key. The same
message/Agreement pair is also bound into the envelope's authenticated context.
The final message UUID is generated before sealing; Cell storage rejects reuse of a live message ID.
Old envelopes without attachments preserve their original signing/AAD format.

`CorrespondenceAgreementTemplates.withAttachments` is an explicit extension of
the four message capabilities. Existing signed Agreements do **not** acquire
new grants. All attachment operations enter the existing CorrespondenceCell
through Resolver/Meddle. Sender mutations must use its currently admitted
originating Agreement. Recipient operations require the recipient's current
exact grant (or existing native owner proof), and storage checks the original
message/Agreement pair. A recipient may have a different subject-bound Contract;
that does not rewrite the attachment's originating Agreement ID.

Every sender has a distinct `CorrespondenceAttachmentCell`, owned by that
sender's public signing identity, with its own file storage. The relationship
Cell hosts these components and exposes their operations through its Agreement
boundary; they are not a shared relationship-owned blob bucket. Physical hosting
is the relationship runtime in this version, **not necessarily the sender's
laptop**. The host administrator remains part of the storage trust boundary.
Copy stream keys stay in the sending client and encrypted message. Source keys
exist transiently at the sender Cell, which already holds that source's bytes.

Host integration can call `configureAttachmentStorage` before first use and
`registerAttachmentSource` with a proven sender. These local provisioning APIs
are not remote path-reading tools. Register only immutable file versions. The
source reader checks size and modification date on each chunk. This detects
ordinary edits, not malicious same-size/mtime replacement by the storage host.

## Mode selection

There is no caller-selectable mode field.

1. `reference`: a registered retained source has an explicit shared reference,
   and every recipient has verified local access to it within five minutes.
   Sending and fetching return the existing reference. No stream is created,
   no file bytes are copied and no new recipient ownership is granted.
2. `fetchOnDemand`: a registered source remains in the sender Cell, but no
   currently verified shared reference reaches every recipient. Encryption and
   chunk production start only on explicit fetch.
3. `copy`: a local file must be imported because it is outside the registered
   Cell source space, or the registered source's storage policy declines
   retention. A sender cannot choose this mode instead of an already resolved
   source by passing a `mode` flag.

The first shared-reference adapter is a file/shared-volume URL. The sender's
reference must resolve to the registered file, and the recipient actually tests
readability and size without reading content. Probe evidence is authenticated
recipient evidence, not a promise made by the sender. Unknown/stale reachability
uses fetch-on-demand and the reason says so; it is not reported as a measured
network outage. Other reference namespaces require their own adapters. Shared
storage must give the same URL the same meaning at both ends.

The returned reason records the decision. Pre-fetch display contains name,
media type and byte count, plus mode/control information. No content hash or key
is returned to the MCP caller. Reference URLs are shown only for explicitly
configured shared sources.

## Streaming and failures

The wire stream is the existing `AttachmentStreamV1`: 64 KiB data chunks and an
authenticated empty final chunk. There is no total-file-size limit in this
protocol. Each request carries one chunk, and receivers retain bounded memory.
`AttachmentStreamOpener` adds incremental verification of the same format;
`CorrespondenceAttachmentFileReceiver` quarantines plaintext under a private
`.partial` name, checks sequence, AEAD, final marker and signed size, fsyncs and
renames only on completion. The convenience buffer-based decoder is unchanged.

An interrupted upload cannot publish a message with an incomplete copy.
Interrupted/tampered downloads fail without publishing a partial final file.
Write errors, including ENOSPC, are returned. Sender-side write failure revokes
the incomplete entry and removes its chunk directory; receiver-side write
failure closes/removes its partial. Cleanup failure is a separate explicit error.
No automatic retry follows an ambiguous message-publication result.

Copy chunks and metadata are persisted. A fetched source stream is retained as
ciphertext until expiry so it can be replayed without reusing an encryption
nonce. After process restart, an unfinished source stream cannot resume: its
in-memory single-use sealer is gone. It fails closed, and the sender must make a
new delivery from the original. Completed source streams and completed copies
can be fetched again. No new stream format or caller-supplied sealing key is used.

## Lifetime and transfer

Unpublished imports expire after one hour. Publication replaces that deadline
with the **actual message expiry** computed from `retentionSeconds`. Every access
checks expiry. Sender/receiver timers remove managed bytes while running;
restored sender Cells and loaded clients sweep overdue data. Physical removal
while the process/host is stopped waits for restart. Filesystem deletion is not
secure erasure and does not remove backups or user-made copies.

A reference recipient already had access to the source. Message expiry removes
the message-scoped reference capability, not that pre-existing file. Managed
fetch/copy downloads expire with the message. The sender can revoke future
fetches; plaintext a recipient has already read cannot be cryptographically
recalled. A separate `ackMessage` is never treated as a file receipt.

Only `copy` offers ownership transfer, and only after the recipient has fetched
all chunks and its client has authenticated, synchronized and published the file.
The sender must explicitly confirm:

> I understand: the recipient owns this file; I cannot revoke it and it will not expire with the message.

An explicitly configured owner policy can supply this answer. The action is
still named, and the consequence stays visible. The sender first offers transfer;
the recipient explicitly accepts and exports its verified download. A durable
server transfer record precedes deletion of the sender's managed copy. Acceptance
is retryable and survives message expiry after commitment. It never deletes the
sender's original external file, overwrites a destination, opens or runs a file.

The recipient writes an intent before the remote acceptance call. If the reply
is lost, it reconciles server state. An unresolved intent is quarantined beyond
TTL to avoid destroying a possibly transferred file; it is **not reported as
transferred**. An explicit retry is required. This exceptional unresolved state
is reported as an error, not a successful expiry/transfer.

## Operations

All are SET actions with exact `-w--` grants:

| Keypath | Effect and limit |
| --- | --- |
| `attachments.probe` | Source metadata/recipient reachability evidence; no content bytes or new grant. |
| `attachments.prepare` | Select mode/reserve delivery; no message publication or ownership transfer. |
| `attachments.upload` | Import one encrypted chunk; cannot replace a published attachment. |
| `attachments.metadata` | Read live delivery metadata; no bytes or receipt. |
| `attachments.fetch` | One sequential encrypted chunk for streamed modes; reference mode has no chunk stream. |
| `attachments.receipt` | Record authenticated client's completed fetch; not message acknowledgement. |
| `attachments.revoke` | Original sender revokes a managed delivery; not a transferred file or external original. |
| `attachments.transfer` | Original sender offers copy ownership transfer after receipt and confirmation. |
| `attachments.acceptTransfer` | Receipted recipient accepts offer; durable record then sender-copy cleanup. |
| `attachments.status` | Read transfer state, including committed transfers after message expiry. |

No operation authorizes file execution, installation, machine actions, broader
file access or inferred consent from correspondence text.

Book follow-up belongs in chapters 04 (Agreements), 05 (lifetime), 08 (stream
transport) and 21 (contact/correspondence). This change does not edit the Book.
