# Vegar Claude CellProtocol Skills

Date: 2026-05-20

This package contains Claude-compatible HAVEN/CellProtocol skills.

## Install

Copy the skill folders from `skills/` into:

```bash
~/.claude/skills/
```

Then restart Claude Code or Claude Desktop so the skill list is reloaded.

## Included Skills

- `cellconfiguration-skeleton-authoring`
- `cellprotocol-cell-authoring`
- `cellprotocol-contract-testing`
- `cellprotocol-core-runtime-implementation`
- `cellprotocol-cross-language-porting`
- `cellprotocol-docs-and-rag-maintenance`
- `cellprotocol-identity-capability-security`
- `cellprotocol-scaffold-integration`
- `cellprotocol-skeleton-renderer-porting`
- `cellprotocol-transport-bridging`
- `haven-git-workflow`

## Intended Use

- Use `cellconfiguration-skeleton-authoring` for pure CellConfiguration and
  skeleton JSON work.
- Use `cellprotocol-cell-authoring` for normal Swift Cell work.
- Use `cellprotocol-cross-language-porting` for Kotlin/Java first, and later
  Rust/Go runtime work.
- Use `cellprotocol-skeleton-renderer-porting` when implementing a renderer or
  parser in another UI/runtime.
- Use `cellprotocol-contract-testing` to prove compatibility through fixtures,
  replay determinism, resolver policy, and golden JSON tests.
- Use `haven-git-workflow` when preparing branches, commits, submodule updates,
  PRs, and cross-repo handoffs.

The skills intentionally operate at different levels so a task that only needs
CellConfiguration authoring does not have to load full CellProtocol runtime
context.

## Source

Canonical local source on Kjetil's machine:

```text
/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/commons/skills
```
