---
name: cellprotocol-identity-capability-security
description: Use when working on HAVEN/CellProtocol identity, domain-scoped identity, IdentityVaults, ownership proofs, agreements, conditions, capabilities/grants, authorization policy enforced by the resolver, privacy boundaries, or security-sensitive access changes. Resolver mechanism changes belong in cellprotocol-core-runtime-implementation.
---

# CellProtocol Identity Capability Security

Use this skill when a task can affect who may read, write, connect, publish,
prove, or act inside CellProtocol.

## Core Rules

- No authority without explicit capability, condition, agreement, or approved
  owner path.
- Identity is domain-scoped. Do not introduce global user/account identity as a
  protocol authority.
- Resolver enforcement is the policy boundary. Do not bypass it for convenience.
- Changes to what the resolver decides belong here. Changes to how the resolver
  engine dispatches or implements enforcement belong in
  `cellprotocol-core-runtime-implementation`.
- Ownership proofs and vault behavior are security-sensitive.
- Denial behavior is part of the contract and must be tested.
- Private state, public read models, and transport payloads must be separated.
- Do not treat QR payloads, deep links, or bridge input as authority by itself.

## Read First

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/03_Identity_Model.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/04_Agreements_Contracts.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocolDocuments/Book/06_CellResolver.md`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/SECURITY.md`

Common source anchors:

- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Identity`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellApple/IdentityVault.swift`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Agreement`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Sources/CellBase/Cells/CellResolver`
- `/Users/kjetil/Build/Digipomps/HAVEN/CellProtocol/Tests/CellBaseTests`

## Required Workflow

1. Identify the protected resource and requested action.
2. Identify the requester identity domain and proof path.
3. Identify the agreement/condition/capability that grants authority.
4. Trace the resolver or vault path that enforces the decision.
5. Add or update tests for:
   - allowed access
   - denied access
   - forged or missing identity/proof where relevant
   - wrong domain or stale capability where relevant
6. Check whether any persisted or public read model leaks private data.
7. Document any new security contract or limitation.

## Red Flags

Stop and ask before:

- adding "temporary" bypasses
- accepting global IDs as authorization
- treating possession of a link or QR payload as sufficient authority
- broadening owner/admin behavior
- weakening signature/proof checks
- exposing private state through skeletons, public profiles, logs, or diagnostics
- moving policy decisions into transport code

## Output Requirements

Report:

- protected resource/action
- authority path
- tests run
- residual security assumptions
- docs updated or needed
