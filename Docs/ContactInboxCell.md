# Independently owned contact inboxes

This is a source-only implementation candidate ported from `937fa0ba3538d9102b2c0948e75726c57d15d4c3` onto server baseline `bff86c16aa9029c3a3e11a714cdc05d0a134a49f`. The Cell and its six test methods retain the donor bytes. This successor has not been compiled, run, released or accepted in the installed native/web surfaces.

Each ContactInboxCell has its own UUID, owner, owner-approval policy and encodable authorization snapshot. Its sole shareable grant is `contact.request` with `-w--` access, bound to the subject signing identity, this Cell UUID and `domain:contact-inbox:v1`. The subject is the permitted sender; the addressed Cell's owner is the recipient. Possessing a reference or forwarding another subject's signed Contract confers no authority. No functional limit on the number of Cells is introduced.

| Operation | Authority | Result |
| --- | --- | --- |
| state | Owner | Settings, active issued grants and unexpired inbox entries |
| agreement.issue | Owner | Signed canonical exact-cell Contract, duration 1 second to one year |
| agreement.accept | Proven contract subject | Canonical external admission; owner signature and all restrictions checked |
| contact.request | Admitted subject, optionally presenting grant on first use | Queued receipt with ticketId, requestID and contactCell |
| access.revoke | Owner | Canonical subject cutoff, including unused offers |
| agreement.revoke | Proven requester presenting valid owner-signed revocation | Canonical signed revocation; requires the admitted contract |
| settings.update / retire / inbox.clear | Owner | Updated status; no expansion of posting rights |

A contact request contains a nonempty requestID of at most 128 UTF-8 bytes, a future expiresAt no more than seven days away and an opaque JSON payload of at most 32 KiB. The contact cell does not interpret that payload as instructions or authorization. Repeating the same sender/requestID and identical payload/expiry returns the same receipt; changed payload or expiry is rejected. Explicit inbox.clear removes this local idempotency evidence.

The registry helper discloses only grants issued to the proven requesting subject. The posting grant provides no state read or administration rights. GeneralCell's existing owner-read and verified identity-link policy remains in force; owner administration additionally requires `requesterProvesOwnership`. `available`, `quiet` and `offline` are local routing settings. In the reference CellScaffold host all three retain the inbox item; only available permits a notification attempt. Queueing is not proof of external-channel delivery or recipient acceptance.

The Cell itself holds encoded state; durability is a host responsibility. The reference CellScaffold ContactInboxHost uses encrypted copy-on-write files and swaps the committed Cell only after persistence succeeds. Cached references consult the current host state, so deletion makes existing handles fail. These are source-observed integration requirements, not execution evidence for this successor. The six Cell tests include fresh Codable decode, not a fresh process or power-loss test. An atomic file write alone does not establish operating-system crash/power-loss durability.

Chat independently requires receiver acceptance before membership. Its persisted invitation attempt preserves request identity and payload across failure between contact queueing and chat commit. This is recovery-on-retry, not a claim of one atomic transaction across both stores.

The reference host resolves local named Cells. Cross-host authenticated delivery, a complete external-channel adapter matrix, existing ContactEndpoint migration and replayable contact Flow events are not implemented by this candidate. The host must address the selected recipient's exact Cell and present the sender's own proven identity and grant; the payload cannot substitute either identity. Local-host tests cannot prove cross-scaffold delivery or physical Binding continuation of the same conversation. The explicitly opaque payload field in Explore metadata is intentional; cryptographic identity and grant checks never depend on its contents.

Historical donor evidence relative to the HAVEN workspace: Binding/Implementation/ChatContactRepair-20261111/evidence/. It is not a test receipt for this successor. ContactInboxCellTests declare independent grants, wrong-subject/cell denial, fresh-decode revocation, immediate renewal, idempotency and input/receipt metadata. The source inventory for the port adds the two existing IdentityVaultBindingConcurrencyTests from the baseline, for eight required CP methods. App tests separately target encrypted persistence, sender-authenticated posting, group retry, HTTP admission and storage-failure recovery; their composition and execution require the new CP pin. Existing broader security gates remain required. No Swift discovery or execution is claimed by this source inventory.
