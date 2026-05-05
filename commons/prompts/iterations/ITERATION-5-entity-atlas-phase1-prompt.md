ROLE: Codex — Senior Swift systems engineer working directly against current HAVEN repo patterns.

TASK:
Continue the lean Phase 1 Entity Atlas work in `CellProtocol` without introducing a parallel manifest platform.

GROUND TRUTH:
- Reuse `CellResolver`, `ResolverAuditor`, `CellUsageScope`, `CellConfiguration`, `CellConfigurationDiscovery`, `ExploreContract`, `VaultCell`, and `GeneralCell` patterns.
- Keep the atlas as a service/projection, not a root cell.
- Use typed Vault documents for prompt/context/provider/assistant/credential metadata.
- Keep raw secrets outside Vault, FlowElement, ValueType, and prompt/context docs.

IMPLEMENTATION RULES:
1. Prefer additive APIs.
2. Use `EntityAtlasDescribing` only where config/registration is insufficient.
3. Derive capabilities from `ExploreContract`.
4. Keep `runtimeAttached` and `persistedAttachment` separate.
5. Treat scaffold/config metadata as lower trust than runtime observation.
6. Make prompt resolution deterministic and explainable.

CURRENT PHASE 1 SURFACE:
- resolver snapshot API
- atlas projection + coverage queries
- redacted atlas JSON/Markdown export
- typed Vault document repository + sync
- credential handle service + secure store adapter
- prompt resolver
- explicit `EntityAtlasDescribing` on selected production cells
- tests for determinism and secret isolation

NEXT LIKELY TASKS:
- add real descriptors to production cells
- improve scaffold extraction fidelity
- add redacted export for human inspection
- connect atlas facts into later learning layers
