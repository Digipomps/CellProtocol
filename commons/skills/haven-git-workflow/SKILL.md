---
name: haven-git-workflow
description: Use when committing, branching, pushing, opening or reviewing PRs, addressing review comments, checking GitHub Actions status, reviewing diffs, handling dirty worktrees, coordinating HAVEN multi-repo changes, syncing submodules, or preparing safe handoffs across CellProtocol, CellProtocolDocuments, CellScaffold, Binding, DiMy, and related HAVEN repositories.
---

# HAVEN Git Workflow

Use this skill for git operations in HAVEN workspaces. It is intentionally more
specific than generic git advice because these repos often have dirty worktrees,
submodules, companion documentation repos, and cross-repo runtime coupling.

## Core Rules

- Start with `git status --short` in every repo you may touch.
- Never revert user changes unless the user explicitly asks.
- Keep commits scoped to the actual task.
- Prefer small branch/commit names with the `codex/` prefix unless the user
  requested another convention.
- Treat `CellProtocol`, `CellProtocolDocuments`, `CellScaffold`, and `Binding`
  as separate repos even when they appear together in a workspace.
- When code changes protocol behavior, include documentation changes or explain
  why docs were not changed.
- Before pushing/opening PRs, run relevant tests or state exactly what was not
  run.
- Do not use destructive git commands without explicit user approval.

## Repo Map

Common local repos:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellScaffold`
- `/Users/kjetil/Build/Digipomps/HAVEN/Binding`
- `/Users/kjetil/Build/Digipomps/HAVEN/DiMyDocuments`

## Required Workflow

1. Identify repos touched by the task.
2. Run `git status --short` in each touched repo.
3. Separate user-existing changes from your changes.
4. Inspect diffs before staging.
5. Stage only intended files.
6. Commit with a clear message when the user asks for a commit or when the
   workflow explicitly requires one.
7. Push/open PR only when requested or when the user has asked for publish/PR.
8. Include test results and any dirty unrelated work in the final handoff.

## Dirty Worktree Handling

- If unrelated files are dirty, leave them alone.
- If a file you must edit is already dirty, inspect it and work with the current
  contents.
- If user changes make the requested task ambiguous or unsafe, stop and ask.
- Do not "clean up" generated or untracked files unless the task is specifically
  cleanup.

## Cross-Repo Handoff

When behavior spans repos, include:

- code repo commit/branch
- docs repo commit/branch if changed
- app/scaffold repo commit/branch if changed
- order of application/deployment
- tests run in each repo
- known unresolved gaps

Submodule ordering:

- Always commit and push the submodule repo, for example `CellProtocol`, before
  updating the pointer in a consumer repo such as `CellScaffold` or `Binding`.
- Never include a submodule pointer update in the same commit as the submodule's
  own changes.

## GitHub/CI

Use GitHub plugin skills when available for PR work:

- `github:yeet` for publishing a branch/PR.
- `github:gh-fix-ci` for failing CI.
- `github:gh-address-comments` for review comments.

Use `gh` CLI when connector coverage is insufficient or thread-level review
state is needed.

## Must Not

- Do not run `git reset --hard`, `git clean`, or destructive checkout commands
  without explicit approval.
- Do not stage broad directories without inspecting what will be included.
- Do not mix unrelated CellProtocol, app, and docs work in one commit unless the
  behavior genuinely requires it.
- Do not claim CI passed without checking.

## Completion Checklist

- Status checked.
- Diff reviewed.
- Only intended files staged/committed.
- Tests/checks reported.
- Remaining dirty/untracked files disclosed when relevant.
