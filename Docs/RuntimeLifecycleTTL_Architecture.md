# Runtime TTL Lifecycle Architecture (Deterministic/Replay-Safe)

## 0) Pre-Implementation Conflict Analysis (must be resolved before rollout)

This section documents conflicts between the existing resolver lifecycle hooks and the required runtime TTL model.

### Conflict C0.1: Wall clock usage in lifecycle path
- Existing runtime path uses `Date`/`TimeInterval` (`ResolverLifecycleTracker`, `CellLifecycleEvent`, sweep loop).
- Files:
  - `Sources/CellBase/Cells/CellResolver/Cast/ResolverLifecycleTracker.swift`
  - `Sources/CellBase/Cells/CellResolver/CellLifecycle.swift`
  - `Sources/CellBase/Cells/CellResolver/CellResolver.swift`
- Impact: violates "no wall clock in cell logic/runtime lifecycle transitions".
- Resolution: new runtime lifecycle uses monotonic ticks from `MonotonicTimeSource`.

### Conflict C0.2: O(N) sweep over all tracked cells
- Existing resolver sweep iterates all tracked dictionaries each run.
- Impact: does not scale predictably for 100k-500k active cells.
- Resolution: hierarchical timing wheel with bounded per-tick processing.

### Conflict C0.3: No lease/fencing in existing lifecycle eviction/delete path
- Existing resolver hook can evict/delete without distributed lease owner/fencing.
- Impact: split-brain risk for multi-node deployments.
- Resolution: lease + fencing token in every runtime transition input.

### Conflict C0.4: Persisted delete without tombstone gate
- Existing deletion path directly removes persisted files.
- Impact: lacks tombstone grace window and auditable delete staging.
- Resolution: `persistedExpiry -> tombstoned -> hardDelete` transition with explicit tombstone effect before physical delete.

### Conflict C0.5: Replay retention semantics are not implemented in legacy flow
- Replay docs explicitly state ledger/retention enforcement is deferred.
- Files:
  - `Docs/ReplayFlow_PR1.md`
  - `Docs/ReplayFlow_PR2.md`
- Impact: replay decisioning must remain explicit and fail-closed when gaps exist.
- Resolution: additive replay policy interface + error semantics in runtime lifecycle.

### Truth-source baselines used
- Cell identity primitive currently used by runtime is `Emit.uuid`:
  - `Sources/CellBase/Protocols/CellProtocol.swift`
- Scaffold lifecycle bootstrap location:
  - `Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift`
- Persistence load/store path:
  - `Sources/CellBase/PersistingCells/TypedCellsUtility.swift`
  - `Sources/CellApple/FileSystemCreationSpaceStorage.swift`

### Implementation status (current)
- `P0` shadow runtime lifecycle is now active-capable in resolver without changing legacy authority:
  - `CellResolver.enableRuntimeLifecycleShadowMode(...)`
  - runtime wheel processing loop runs in parallel with existing legacy sweep
  - legacy `ResolverLifecycleTracker` still decides actual eviction/delete behavior.
- Runtime lifecycle Flow events are now wired in scaffold bootstrap:
  - `AppInitializer.setupPorthole()` enables runtime shadow mode using resolver emitter
  - runtime events topic: `runtime.lifecycle`
  - runtime metrics topic: `runtime.lifecycle.metrics`.
- Encrypted persisted snapshots are now supported and enforced when policy requires it:
  - additive storage write options include `encryptedAtRestRequired` and `ownerIdentityUUID`
  - persisted payload envelope uses authenticated encryption and is backward-compatible for plaintext reads
  - resolver persistence path derives encryption requirement from agreement lifecycle mapping.

---

## A) Formal runtime lifecycle state machine

State machine:
- `M = (S, I, G, T, E)`
- `S = {activeLoaded, activeUnloaded, tombstoned, deleted}`
- `I` inputs:
  - `touch`
  - `extendMemoryTTL`
  - `extendPersistedTTL`
  - `persistAndUnloadNow`
  - `requestTombstone`
  - `loadIntoMemory`
  - `unloadFromMemory`
  - `memoryWarningFired(generation, fence)`
  - `memoryExpiryFired(generation, fence)`
  - `persistedExpiryFired(generation, fence)`
  - `hardDeleteFired(generation, fence)`
  - `leaseGranted`
  - `leaseExpired`
- `G` guards:
  - fence equality (`providedFence == state.fencingToken`) for mutable lifecycle ops.
  - generation monotonicity for expiry idempotency.
- `T` transition function:
  - implemented in `RuntimeLifecycleTransitionReducer.reduce`.
- `E` effects:
  - schedule/cancel warning+expiry entries, unload/persist/tombstone/hard-delete side effects, lifecycle event emission.

Versioning/CAS invariants:
- Every state mutation increments `version`.
- Manager applies transitions through `compareAndSwap(expectedVersion, nextState)`.
- CAS retry loop bounds contention retries.

Idempotency invariants:
- Duplicate expiry deliveries are dropped by generation checks (`lastProcessed*Generation`).
- Stale wheel entries are dropped by `(cellID, kind, generation)` latest-generation index.

Hard delete safety invariant:
- Persisted data hard delete is reachable only through:
  - `active*` -> `tombstoned` (write tombstone) -> `deleted` (hard delete).

---

## B) Hierarchical timing wheel implementation

Implementation file:
- `Sources/CellBase/RuntimeLifecycle/RuntimeHierarchicalTimingWheel.swift`

Concrete data structures:
- `levels: [RuntimeWheelLevel]`
- each level has `slots: [Deque<RuntimeWheelNode>]`
- `latestGenerationByKey: [RuntimeWheelKey: UInt64]` (stale suppression)
- `pendingDueOverflow: Deque<RuntimeWheelNode>` (bounded expiry spillover)
- `pendingCascadeJobs: Deque<RuntimeCascadeJob>` + `pendingCascadeSet` (bounded rebucket continuation)
- memory warning is a first-class wheel kind (`memoryWarning`) and is delivered ahead of memory expiry when `memoryWarningLeadTicks > 0`.

Complexity:
- schedule: `O(1)` average
- cancel: `O(1)` average
- advance per tick: `O(levelCount + maxRebucketPerTick + maxExpiredPerTick)`
- memory: `O(activeScheduledItems + levels * slots)`

Scaling notes for 100k-500k cells:
- No per-cell timers.
- Processing is bounded by configuration each tick.
- Backlog is explicit (`pendingDueOverflow`) instead of hidden starvation in wheel slots.

---

## C) Additive Swift interfaces (no CellProtocol breakage)

New additive interfaces/types:
- `MonotonicTimeSource`, `DeterministicTimeSource`
- `RuntimeLifecyclePolicy`, `RuntimeMemoryExpiryAction`
- `RuntimeLifecycleState`, `RuntimeLifecycleInput`, `RuntimeLifecycleEffect`
- `RuntimeLifecycleStateStore`
- `RuntimeLease`, `RuntimeLeaseCoordinator`
- `RuntimeHierarchicalTimingWheel`
- `RuntimeLifecycleManager`
- `RuntimeLifecycleWarningCommand` fenced/CAS command route
- `RuntimeLifecycleFlowEventSink` flow emitter for runtime lifecycle events
- `RuntimeLifecycleAgreementMapper` + agreement resolution structs
- `RuntimeReplayPolicy`, `RuntimeReplayError`, `RuntimeReplayResolution`
- `RuntimeLifecycleMetricsSink`

No existing `CellProtocol` contract changed.

### C.1 Alarm routing authorization (implemented)

Goal:
- lifecycle alarms must only be delivered to:
  - cell owner
  - identities explicitly granted via agreement condition
  - optional signatories when enabled by condition.

Additive agreement condition:
- `LifecycleAlertAccessCondition`
  - `allowedIdentityUUIDs: [String]`
  - `includeSignatories: Bool`

Resolver routing model:
- Resolver keeps an in-memory emitter registry by identity UUID.
- `setResolverEmitter(_:, requester:)` binds emitter to requester identity UUID.
- Lifecycle tracking snapshots recipient set at track time:
  - owner UUID (always)
  - fallback requester identity UUID
  - `LifecycleAlertAccessCondition.allowedIdentityUUIDs`
  - signatories when `includeSignatories == true`
- `publishLifecycleEvent` dispatches only to emitters whose identity UUID exists in `recipientIdentityUUIDs`.
- If an identity has no registered emitter, event is not fan-out broadcast; it is skipped for that identity.

Security invariant:
- No lifecycle alarm broadcast to global/default listeners when recipient set is present.
- Unauthorized identities can register emitters, but they receive no lifecycle alarm unless explicitly included in agreement-derived recipient set.

---

## D) Lease + fencing model

Semantics:
- Lease owner obtains `(cellID, ownerNodeID, fencingToken, validUntilTick)`.
- Fencing token is strictly monotonic per `cellID` (including after release).
- Every mutable lifecycle transition requires matching fencing token.
- Stale owner writes fail deterministically (`staleFence` rejection).
- Warning-response commands (`extend`, `persistAndUnload`, `delete`) are routed through `RuntimeLifecycleManager.applyWarningCommand(...)`, which enforces the same lease/fencing rules and CAS semantics as ordinary transitions.

Distributed deployment model:
- Replace `InMemoryRuntimeLeaseCoordinator` with a shared coordinator backed by durable storage.
- Required coordinator properties:
  - atomic acquire/renew/release
  - strict per-cell monotonic fencing token
  - lease expiration evaluated against monotonic coordinator time source
  - optional conditional writes (`WHERE fencing_token < new_token` style)

---

## E) Replay error semantics

Implementation file:
- `Sources/CellBase/RuntimeLifecycle/RuntimeReplaySemantics.swift`

Resolution matrix:
- `deleted` -> `loadBlocked(lifecycleDeleted)`
- `tombstoned` -> `loadBlocked(lifecycleTombstoned)`
- event-log gap -> `loadBlocked(eventLogGap)`
- active (loaded/unloaded) + snapshot present -> `replayFromSnapshot`
- active (loaded/unloaded) + no snapshot + no gap -> `replayFromEventLog`

Guarantee:
- Replay decisioning is independent of whether cell is currently in memory.

Agreement-driven replay policy:
- New agreement condition types:
  - `ReplayGuaranteeCondition`
  - `LifecycleFundingCondition`
  - `ColdStorageCondition`
- Mapper file:
  - `Sources/CellBase/RuntimeLifecycle/RuntimeLifecycleAgreementMapping.swift`
- Mapping output includes:
  - effective runtime lifecycle policy (hot TTL, warning lead, cold retention, tombstone grace)
  - replay mode (`none|snapshot|eventLog`)
  - payer identity and funding/billing tier
  - cold-storage encryption requirement.

---

## F) Failure modes and mitigation

F1: Split brain / dual owners
- Cause: lease backend race.
- Mitigation: lease CAS in coordinator + fencing checks in reducer + storage write fencing.

F2: Expiry storm/backlog
- Cause: many cells expiring at same tick.
- Mitigation: `maxExpiredPerTick`, `pendingDueOverflow`, backpressure metric/alert.

F2b: Warning storm before expiry
- Cause: synchronized warning lead windows.
- Mitigation: warning uses same bounded wheel path (`memoryWarning`), same generation idempotency, and same overflow queue.

F3: Cascade starvation
- Cause: rebucket budget exhaustion.
- Mitigation: persistent cascade queue (`pendingCascadeJobs`) resumed next ticks.

F4: Duplicate/out-of-order expiry delivery
- Cause: retries, delayed wheel entries.
- Mitigation: generation idempotency in reducer + latest-generation drop in wheel.

F5: Tombstone write succeeds but hard delete fails
- Cause: storage outage or partial failure.
- Mitigation: retry hard delete effect; keep tombstone until success; expose failure metric.

F6: CAS contention hotspot
- Cause: heavy concurrent touch/lease updates.
- Mitigation: bounded retry budget + conflict metrics + partitioning by cell ownership.

F7: Legacy hook collision
- Cause: resolver wall-clock sweep active at same time as runtime wheel.
- Mitigation: phased migration with exclusive mode switch (see section I).

---

## G) Metrics and observability design

Metric namespace:
- `lifecycle.*` (see `RuntimeLifecycleMetric`)

Core counters/gauges:
- state gauges: activeLoaded/activeUnloaded/tombstoned/deleted
- wheel: scheduled_total, expired_total, stale_dropped_total
- CAS: success_total, conflict_total
- lease: acquire_success_total, acquire_failure_total
- expiry: memory_total, persisted_total, hard_delete_total
- replay: blocked_total
- lifecycle events should include `memoryTTLWarning` and command-route metadata for listeners.

Recommended additional production metrics:
- `lifecycle.wheel.pending_due_overflow`
- `lifecycle.wheel.pending_cascade_jobs`
- `lifecycle.transition.rejection_total{reason=...}`
- `lifecycle.effect.failure_total{effect=...}`

Tracing dimensions:
- `cell_id`, `node_id`, `phase`, `fencing_token`, `generation`, `policy_mode`.

Implemented metric emission points:
- lease acquire success/failure
- CAS success/conflict
- wheel scheduled/expired
- expiry by kind (`memory`, `persisted`, `hard_delete`)
- phase gauges (`activeLoaded`, `activeUnloaded`, `tombstoned`, `deleted`).

---

## H) Property tests (deterministic time)

Implemented tests:
- `testTimingWheelExpiresOnlyAtOrAfterDeadline`
- `testTimingWheelGenerationReplacementIsIdempotent`
- `testReducerIsIdempotentForDuplicateExpiryDelivery`
- `testManagerAppliesTombstoneBeforeHardDelete`
- `testOwnerCanExtendMemoryTTLDeterministically`
- `testMemoryWarningEventFiresBeforeExpiry`
- `testWarningCommandRoutePersistAndUnload`
- `testAgreementMappingResolvesReplayFundingAndColdTier`
- `testAgreementMappingFailsWhenSnapshotReplayHasNoColdTier`
- `testReplayPolicyAllowsUnloadedReplayFromEventLog`

File:
- `Tests/CellBaseTests/RuntimeLifecyclePropertyTests.swift`

Test time source:
- `DeterministicTimeSource` monotonic tick control.

---

## I) Migration plan (P0 / P1 / P2)

P0 (Shadow mode, no behavior change)
- Keep legacy resolver lifecycle active.
- Run runtime lifecycle in parallel as observer-only (event/metric parity checks).
- Validate wheel load, lease churn, CAS contention.
- Current code status:
  - implemented in `CellResolver` + runtime manager integration
  - enabled from `AppInitializer` once resolver emitter is ready.

P1 (Runtime lifecycle authoritative for selected resolves)
- Add resolver-level mode switch per resolve/domain:
  - legacy sweep OFF for migrated cells
  - runtime manager ON with effect sink adapters
- Enable owner responses (`extendMemoryTTL`, `extendPersistedTTL`) via runtime APIs.
- Persist tombstones before hard delete for migrated persisted cells.

P2 (Cluster-safe full rollout)
- Shared lease coordinator with strict fencing.
- Storage fencing enforcement on side effects.
- Runtime replay policy integrated with eventual event-log retention policy.
- Decommission legacy `Date`-based lifecycle sweep path.

---

## Optional Deep Research Prompt (for external validation)

Use this prompt if you want an external architecture review:

> Review this TTL/runtime lifecycle design for a deterministic, replayable distributed actor/cell runtime.  
> Constraints: no wall-clock in reducer, monotonic time source only, 100k-500k active cells/node, no per-cell timers, hierarchical timing wheel, bounded expiry/cascade per tick, CAS-versioned state transitions, lease+fencing for distributed ownership, idempotent expiry handling, persisted tombstone before hard delete, and non-expiring policy support.  
> Please critique failure modes, prove/argue safety invariants (especially fencing and idempotency), evaluate time/memory complexity of the wheel under bursty expiry workloads, and propose concrete parameter tuning for slotBits/levels/maxExpiredPerTick/maxRebucketPerTick at 100k/250k/500k active cells.  
> Also propose chaos test scenarios and SLO-aligned metrics/alerts for production rollout.
