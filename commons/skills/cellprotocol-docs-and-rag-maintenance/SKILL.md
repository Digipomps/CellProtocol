---
name: cellprotocol-docs-and-rag-maintenance
description: Use when updating, auditing, reorganizing, or generating CellProtocol documentation, Book chapters, machine-readable catalogs, agent entrypoints, RAG/discovery indexes, gap analysis, handoff notes, or context-preservation summaries for HAVEN/CellProtocol and companion repositories.
---

# CellProtocol Docs And RAG Maintenance

Use this skill when the durable knowledge layer needs to change, especially
when code behavior, agent workflows, or cross-repo contracts have changed.

## Core Rules

- Documentation must match current code and current known limitations.
- Do not document planned behavior as implemented behavior.
- Do not commit documentation for a behavior change before the implementing code
  is committed. If updating both in one workflow, commit code first, verify it
  landed, then commit docs.
- Keep protocol/runtime behavior in `CellProtocolDocuments`; keep app/product
  behavior in the owning app repo unless it is shared protocol contract.
- Update machine-readable catalogs when user-facing Book structure changes.
- Write for future agents: clear entrypoints, exact paths, and current limits.
- Preserve enough context for recovery before long work risks context loss.

## Read First

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/README-CellProtocol.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/00_Book_Home.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/book_catalog.json`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/15_Documentation_Discovery_and_RAG.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/16_Book_Reference_Workspace.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Gap_Analysis.md`

If code behavior changed, inspect the actual source before editing docs.

## Placement Rules

- Core protocol contracts: `CellProtocolDocuments/Book`.
- Current implementation caveats: relevant Book chapter plus `Gap_Analysis.md`
  if the gap is unresolved.
- Agent workflow: `Book/13_Agent_Instructions.md` or a focused skill.
- App/scaffold behavior: app repo docs, with a pointer from CellProtocol docs
  only if it illustrates shared protocol use.
- Temporary handoff: `Prompts/CurrentState.md` or a dated deliverable when the
  content is project-state rather than canonical spec.

## Required Workflow

1. Identify what changed: code, contract, limitation, workflow, or product docs.
2. Find the authoritative source and compare before editing.
3. Update the smallest doc set that future agents will actually read.
4. Update `book_catalog.json` when Book chapter inventory or metadata changes.
5. Add "current limitation" language when behavior is partial.
6. Avoid marketing claims unless `haven-claim-review` is also applicable.
7. Validate links/paths and run any local catalog checks if present.

## RAG Hygiene

- Prefer stable headings and concise summaries.
- Put exact file paths near operational instructions.
- Keep examples minimal and schema-valid.
- Split large docs by task area instead of creating giant catch-all chapters.
- Include negative boundaries: what is not supported and what requires approval.

## Completion Checklist

- Docs align with current code or clearly state planned/gap status.
- Book index/catalog updated if needed.
- Agent entrypoint remains easy to find.
- No stale cross-repo paths were introduced.
- Any uncertainty is explicitly called out.
