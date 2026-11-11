# Independently owned contact inboxes

This is a local implementation candidate. It has not been released or accepted in the installed native/web surfaces.

Each ContactInboxCell has its own UUID, owner, owner-approval policy and durable authorization snapshot. Its sole shareable grant is `contact.request` with `-w--` access, bound to the subject signing identity, this Cell UUID and `contact-inbox:v1`. Possessing a reference or forwarding another subject's signed Contract confers no authority. No functional limit on the number of Cells is introduced.

| Operation | Authority | Result |
| --- | --- | --- |
| state | Owner | Settings, active issued grants and unexpired inbox entries |
| agreement.issue | Owner | Signed canonical exact-cell Contract, duration 1 second to one year |
| agreement.accept | Proven contract subject | Canonical external admission; owner signature and all restrictions checked |
| contact.request | Admitted subject, optionally presenting grant on first use | Queued receipt with ticketId, requestID and contactCell |
| access.revoke | Owner | Canonical subject cutoff, including unused offers |
| agreement.revoke | Proven requester presenting valid owner-signed revocation | Canonical signed revocation; requires the admitted contract |
| settings.update / retire / inbox.clear | Owner | Updated status; no expansion of posting rights |

A contact request contains a nonempty requestID of at most 128 characters, a future expiresAt no more than seven days away and an opaque JSON payload of at most 32 KiB. The contact cell does not interpret that payload as instructions or authorization. Repeating the same sender/requestID and identical payload/expiry returns the same receipt; changed payload or expiry is rejected. Explicit inbox.clear removes this local idempotency evidence.

The registry helper discloses only grants issued to the proven requesting subject. Context and inbox contents remain owner-only. `available`, `quiet` and `offline` are local routing settings. In the current CellScaffold host all three retain the inbox item; only available permits a notification attempt. Queueing is not proof of external-channel delivery or recipient acceptance.

The Cell itself holds encoded state; durability is a host responsibility. CellScaffold ContactInboxHost uses encrypted copy-on-write files and swaps the committed Cell only after persistence succeeds. Cached references consult the current host state, so deletion makes existing handles fail. Re-instantiation from disk is tested; operating-system crash/power-loss durability is not established by an atomic file write alone.

Chat independently requires receiver acceptance before membership. Its persisted invitation attempt preserves request identity and payload across failure between contact queueing and chat commit. This is recovery-on-retry, not a claim of one atomic transaction across both stores.

The current host resolves local named Cells. Cross-host authenticated delivery, a complete external-channel adapter matrix, existing ContactEndpoint migration and replayable contact Flow events are not implemented by this candidate. The explicitly opaque payload field in Explore metadata is intentional; cryptographic identity and grant checks never depend on its contents.

Evidence relative to the HAVEN workspace: Binding/Implementation/ChatContactRepair-20261111/evidence/. ContactInboxCellTests cover independent grants, wrong-subject/cell denial, fresh-decode revocation, immediate renewal, idempotency and input/receipt metadata. App tests separately cover encrypted persistence, sender-authenticated posting, group retry, HTTP admission and storage-failure recovery.
