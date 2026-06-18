# Testing SevenDB's premises top-down with TLA+

This document describes how to falsify SevenDB's correctness premises using
TLA+/TLC, working *top-down*: start from the guarantees the project advertises,
turn each into a temporal-logic property, model the layer of the system that is
supposed to provide it at the level of abstraction where the guarantee lives,
and let TLC search for a behavior that violates it. The point is not to model
an idealized SevenDB — it is to encode the **transition relation the code
actually implements** and check whether the advertised invariant survives it.

The approach has already produced one concrete, reproducible bug
(`EmissionContract.tla`, see §4). The rest of this document explains the method
and catalogs the remaining premises and the bug hypotheses worth modeling.

---

## 1. Why TLA+, and why top-down

SevenDB makes strong, *global* claims — "no lost updates", "effective-once",
"gap-free total ordering across migrations", "deterministic replay". These are
properties of whole executions across crashes, restarts, leader changes, and
reconnects. They are exactly the class of properties unit tests and even the
existing 100-run determinism harness cannot cover: those run a *fixed* schedule
many times; they cannot enumerate the adversarial interleavings of fault +
recovery that break global invariants. TLA+/TLC enumerates them exhaustively
within bounded constants.

Top-down means: **the premise is the test.** We do not start from the data
structures. We start from a sentence in the README or design doc, write it as
an invariant or temporal property, and then write the smallest model whose
actions correspond to the real code paths that are supposed to uphold it. When
TLC returns a counterexample, the trace maps back to concrete functions.

A model is only useful if it is *faithful*: every action must correspond to a
real transition in the code, and every modeling assumption must be a real
property of the code (cited). A model that "proves correctness" by quietly
assuming away the bug is worse than no model. Each spec therefore carries an
explicit **code mapping** block (see the header of `EmissionContract.tla`).

---

## 2. The premises, as checkable properties

Harvested from `README.md`, `docs/src/content/docs/architecture/emission-contract.mdx`,
`docs/DETERMINISM.md`, and `docs/RAFT_ARCHITECTURE.md`.

| # | Premise (as stated) | Property class | Formal statement (sketch) |
|---|---------------------|----------------|---------------------------|
| P1 | Effective-once delivery across crashes/reconnect/migration | Safety | For every source delta `d`, the client applies `d`'s effect **at most once**. |
| P2 | At-least-once + idempotent client ⟹ effective-once | Safety + Liveness | Every committed delta is eventually delivered ≥ once (◇), and de-dup makes net effect = 1. |
| P3 | `emit_seq = (bucket,epoch,commit_index)` is a total, **gap-free** order; "a client's single source of truth for stream position" | Safety | The sequence of `emit_seq` the client accepts is strictly increasing **and contiguous** (no skipped index within an epoch). |
| P4 | Durable outbox ⟹ notifier failover loses nothing | Safety | After any notifier/lease change, every un-acked entry is still pending and re-emitted. |
| P5 | Reconnect maps every failure to OK/STALE/INVALID and resumes from `commit_index+1` | Safety | The `ReconnectAck` is a total, correct function of (client position, ack watermark, compaction watermark, epoch). |
| P6 | Migration: old outbox drained before new emissions; monotonic `emit_seq` continuity; "no resets, no duplicates" | Safety | Across an epoch bump, no epoch-N emission is sent before all epoch-(N-1) entries are purged, and the client's accepted order stays monotone & gap-free. |
| P7 | Deterministic subscriptions: same log ⟹ byte-identical emission transcript | Safety (refinement) | Two runs over the same committed log produce equal canonical transcripts under all schedules. |
| P8 | Compaction never passes `safety_point = min(cold checkpoint, min client ack, migration hold)` | Safety | `compactedThrough ≤ min(active client acks)` always. |
| P9 | Notifier lease decoupled from raft leadership, but **exactly one** emitter | Safety | At most one replica is in "emitting" state per (bucket, epoch) at any time. |

---

## 3. Layered spec architecture

Model the system as a stack of refinements so each premise is checked at the
altitude where it lives, with the layers below abstracted to their contract.

```
L4  WAL durability / compaction / snapshot prune      -> P8
L3  Migration & epoch advancement                     -> P6, P3
L2  Reconnect / rebind / watermark reconciliation     -> P5, P3
L1  Emission contract: outbox + notifier + ack/purge  -> P1, P2, P4, P9   <-- start here
L0  Raft log: durable, ordered, re-applied on restart -> assumed contract
```

L0 is **assumed**, not modeled in detail: an ordered, durable log of committed
records that, crucially, is **re-delivered to the apply pipeline from the last
snapshot on restart** (this is a real property — see §4, code mapping). Higher
layers refine downward; a counterexample at any layer is a real bug unless the
modeling assumption it relies on is shown to be false in the code.

Each spec file should contain: the `CONSTANTS` that bound the search, the
`VARIABLES` with a one-line meaning each, a **code mapping** comment block, the
actions, and the invariants/temporal properties named after the premise they
encode (`EffectiveOnce`, `GapFree`, `ReconnectSound`, …).

---

## 4. Result: P1 (effective-once) is violated — `EmissionContract.tla`

**Status: confirmed by TLC.** A 7-state trace shows one source delta delivered
to the client twice in effect.

### Counterexample (TLC output, paraphrased)

1. `Produce(1)` — DATA_EVENT for delta 1 is committed.
2. `LeaderEmit` — leader proposes `OUTBOX_WRITE` under epoch 1 → outbox `{(1,1)}`.
3. `Deliver` — notifier sends `(1,1)`; client applies effect (`effects[1]=1`),
   acks; entry purged.
4. `Restart` — applier mints a new epoch (epoch 2). Durable outbox/purge state
   survives.
5. `LeaderEmit` — on restart the committed log is **re-applied**; the leader
   re-proposes `OUTBOX_WRITE` for the *same* delta 1, now under epoch 2 →
   outbox `{(2,1)}` (resurrected).
6. `Deliver` — client sees `(2,1)`; since `(2,1) > (1,1)` lexicographically, its
   de-dup rule accepts it and applies the effect **again** (`effects[1]=2`).

`EffectiveOnce` (`∀ d : effects[d] ≤ 1`) is violated.

### Root cause (code)

The trace's actions each map to a real path:

- **Re-apply on restart.** `internal/raft/types.go:998` constructs
  `etcdraft.Config{…}` with **no `Applied` field**. etcd/raft therefore
  re-delivers every committed entry above the snapshot after `RestartNode`
  (`types.go:1038`). `RAFT_ARCHITECTURE.md` §11.1 confirms the per-bucket
  commit index is "not persisted; lost on restart."
- **Unconditional re-emit.** `internal/emission/applier.go`, `case
  "DATA_EVENT"`: if `a.node.IsLeader()` it proposes a fresh `OUTBOX_WRITE`,
  with **no check** that this DATA_EVENT was already emitted/acked/purged.
- **Fresh epoch each start.** `internal/emission/applier.go` `NewApplier`:
  `EpochCounter: uint64(time.Now().UnixNano())`. Every restart strictly
  increases the epoch, so the resurrected entry sorts *after* the client's
  last position and defeats client de-dup (which is purely `emit_seq`-ordered,
  per `emission-contract.mdx` §2/§9 and `outbox.go ValidateAck`).
- **Purge is content-blind.** `internal/emission/outbox.go purge()` keys on
  commit index only and keeps no record that delta 1 was already satisfied, so
  nothing suppresses the resurrected write.

The premise assumes client de-dup makes resends harmless. That holds for
resends of the *same* `emit_seq`. It does **not** hold here because the resend
gets a *new, higher* `emit_seq` (new epoch, same delta). The durable outbox plus
unconditional re-emit plus monotonic epoch combine to manufacture a brand-new
identity for an already-delivered effect.

### Fix directions (to validate by re-running the spec)

Any one of these should make `EffectiveOnce` hold; the spec is the regression
test:

1. Persist the applied index / set `etcdraft.Config.Applied` on restart so
   committed DATA_EVENTs are not re-applied and re-emitted.
2. Make the emit step idempotent on the **source identity** (bucket,
   source-commit-index), not on (epoch, commit-index), so a restart cannot mint
   a second emit_seq for the same delta. (In the model: guard `LeaderEmit` on
   `ci ∉ {s.ci : s ∈ owritten}` instead of `seq ∉ owritten`. Re-running TLC with
   that guard makes the invariant pass — a useful discriminating check that the
   model is not vacuous.)
3. Tie `epoch_counter` to a durable, log-derived value rather than wall-clock,
   so a restart that does *not* change lineage does not change the epoch.

---

## 5. Remaining bug hypotheses (model next)

Each was found by code review and is stated as a property a spec can refute.

### H1 — Reconnect always force-restarts to index 0 (P5, P3) — **CONFIRMED** (`Reconnect.tla`)

`internal/cmd/cmd_emitreconnect.go:44` builds the `ReconnectRequest` with
`EpochCounter: 0`, hardcoded. But the live epoch is the wall-clock value from
`NewApplier`. In `outbox.go Reconnect`:

```go
if req.LastProcessedEmitSeq.Epoch.EpochCounter != currentEpoch.EpochCounter {
    return ReconnectAck{Status: ReconnectOK, ..., NextCommitIndex: 0}
}
```

The condition `0 != <nanos>` is **always true**, so reconnect *always* returns
`OK, next=0` and the STALE/INVALID/compaction logic below it is dead code in the
production path. Then `iothread.go:263-264` calls `SetResumeFrom(newSub, 0)`,
and `SetResumeFrom` (`notifier.go:157`) *deletes* the resume entry when next==0.
Net effect: the careful resume protocol degrades to "resend from whatever the
watermarks happen to be," and the documented `STALE_SEQUENCE`-after-compaction
guarantee never fires.

- **Property `ReconnectSound`**: the `ReconnectAck` equals the spec function of
  (client pos, ack, compaction, epoch) from `emission-contract.mdx` §5.2.
- **Result (confirmed by TLC):** violated. `Reconnect.tla` models a same-epoch
  reconnect (network blip, no restart) and checks the production decision
  against the design decision over all `(pos, ack, comp)` with `comp ≤ ack`.
  TLC returns witness `pos=0, ack=0, comp=0`: design wants `OK, next=1`,
  production returns `OK, next=0` — and every input where the design wants
  `STALE`/`INVALID` is likewise collapsed to `OK, next=0`. The module's
  `FixHolds` invariant (thread the client's real epoch instead of the hardcoded
  `0`) passes over all inputs, so the spec is non-vacuous.

### H2/H3 — Cross-epoch outbox loss (P3, P6) — **CONFIRMED** (`Migration.tla`)

`outbox.go purge(sub, upTo.CommitIndex)` removes every entry with
`commitIndex ≤ upTo`, **ignoring epoch**. Combined with the per-bucket commit
index resetting on restart (commit indices restart low under a new epoch), an
ack in a new epoch can purge — or fail to purge — entries from another epoch
incorrectly. The design (§7) says "old outbox entries from the previous epoch
are drained before any new emissions," but there is no epoch-ordered drain.

The outbox is a map keyed by **commit index only** (`outbox.go write()`,
`pendingSorted()` sorts on commit index), while the notifier's skip test is
**epoch-aware** (`notifier.go processTick`: an entry whose epoch is below the
`sentThrough` epoch is skipped forever). After a restart the per-bucket commit
index resets to low values while the epoch advances, so old- and new-epoch
entries collide on commit index. There is also no `EPOCH_CREATE` handler in the
emission applier (`applier.go applyCommand` switch), so nothing performs §7's
"drain previous epoch first."

- **Property `NoLoss`**: every committed delta is either delivered or still
  recoverable from the outbox.
- **Result (confirmed by TLC):** violated in 4 states. epoch 1 writes delta
  `d1` at commit index 1; restart → epoch 2; epoch 2 writes `d2` at commit
  index 1, which **overwrites** `d1` in the commit-index-keyed map → `d1` is
  lost before it is ever delivered. (The epoch-regression *strand* — sending a
  new-epoch low-index entry first, which then permanently skips an old-epoch
  high-index entry — is also reachable.) The `EpochAwareOutbox=TRUE` fix
  variant (key/order by full emit_seq) passes all states.

### H4 — Rebind reconciles three independent watermarks (P1, P5)

There are three watermarks for one logical stream: `Manager.lastAck`,
`Manager.compactThrough` (in `outbox.go`), and `Notifier.sentThrough` +
`Notifier.resumeFrom` (in `notifier.go`). `RebindByFingerprint`
(`outbox.go:191`) moves `lastAck`/`compactThrough`/outbox to the new sub id, but
**not** the notifier's `sentThrough`; the iothread separately calls
`SetResumeFrom` and `ClearWatermarksForClient`. A model of disconnect→rebind→
reconnect with all interleavings should check:

- **Property `GapFree`** (P3): the client's accepted `emit_seq` stream is
  contiguous (no skipped index) and monotone after a rebind.
- **Expected result**: candidate violation where a lingering `sentThrough` on
  the old sub id, or a cleared one on the new, causes either a skipped entry
  (gap → lost update) or a resend after the resume point.

### H5 — Compaction safety point vs. ack watermark (P8) — **CONFIRMED** (`Compaction.tla`)

`emission-contract.mdx` §8 defines `safety_point = min(cold checkpoint, min
client ack, migration hold)` and "the system will never compact beyond
safety_point." In code, raft snapshot+compaction is triggered purely by volume
(`types.go:1461` `committedSinceSnap >= snapshotThreshold`), the snapshot stores
**no application state** (`types.go:1463` `CreateSnapshot(applied, cs, nil)`),
and it then `Compact`/`PruneEntries` at the applied index (`types.go:1469`) with
no reference to client acks. Since the outbox is reconstructed only by replaying
`OUTBOX_WRITE`/`OUTBOX_PURGE` records, pruning them with a nil snapshot loses any
un-acked emission below the snapshot index.

- **Property `CompactSafe`**: `pruned ≤ ackWM` (never compact past the ack
  watermark).
- **Result (confirmed by TLC):** violated in 4 states — two emissions are
  committed with no acks, the snapshot fires at the threshold and prunes through
  the applied index (`pruned=2`) while `ackWM=0`, discarding both un-acked
  emissions. The `AckAwareCompaction=TRUE` fix (clamp the compaction point to
  the ack watermark) passes.

### H6 — Single-emitter / lease vs. leadership (P9) — *open, lower confidence*

Design §6 says exactly one replica emits per (bucket, epoch), via a lease that
is "decoupled from raft leadership," yet the apply path gates emission on
`IsLeader()` (`applier.go`) and the notifier's gated sender is enabled per
leadership (`shardmanager/main.go`). A spec with N replicas, lease handoff, and
a leadership change would check **`AtMostOneEmitter`**.

Caveat (why this is held back): raft (PreVote + CheckQuorum) prevents two
leaders from *committing* `OUTBOX_WRITE`s, and on the send side a stale leader
that briefly double-emits sends the **same** `emit_seq`, which client de-dup is
designed to absorb. So a naive model would report a "duplicate" that is actually
dedup-safe — a false positive. This is only worth modeling if a path is found
where the two emitters can produce **different** `emit_seq`s for the same delta
(e.g. interacting with the §4 epoch resurrection). Model it after a real
divergent-identity path is identified, not before.

### H4 — Rebind reconciles three watermarks (P1, P5) — *open*

`Rebind.tla` (not yet written) should check **`GapFree`** across
disconnect→rebind→reconnect. Note that the cross-epoch ordering hazards this
hypothesis worried about (e.g. `resumeFrom` being a bare `uint64` compared by
commit index, ignoring epoch — `notifier.go:253`) overlap with what
`Migration.tla` already demonstrates; the distinct risk left to model is a
*same-epoch* gap caused purely by the un-migrated `sentThrough` watermark
(`RebindByFingerprint` moves `lastAck`/`compactThrough` but not the notifier's
`sentThrough`).

---

## 6. Suggested order of work

1. **Done:** `EmissionContract.tla` → P1 effective-once (counterexample found).
2. **Done:** `Reconnect.tla` → H1 `ReconnectSound` (counterexample found;
   `FixHolds` confirms non-vacuity).
3. **Done:** `Migration.tla` → H2/H3 `NoLoss` across an epoch bump
   (counterexample found; `EpochAwareOutbox` fix passes).
4. **Done:** `Compaction.tla` → H5 `CompactSafe` (counterexample found;
   `AckAwareCompaction` fix passes).
5. `Rebind.tla` → H4 `GapFree` (same-epoch, un-migrated `sentThrough`).
6. `Lease.tla` → H6 `AtMostOneEmitter` (only after a divergent-`emit_seq` path
   is found; see H6 caveat).
7. A `Determinism` refinement (P7): two log replays under different schedules
   refine the same canonical transcript — checks the headline determinism claim
   against scheduling adversaries, not just repeated fixed runs.

## 7. Faithfulness checklist (apply to every spec)

- Every action cites the function(s) it abstracts.
- Every modeling assumption is a stated, verifiable code property.
- Add a *discriminating* variant (a plausible fix) and show the invariant then
  holds — this proves the spec can distinguish correct from buggy behavior and
  is not vacuously failing.
- Keep constants tiny (1–3 deltas, 2 epochs, 2–3 replicas); these bugs are
  shallow and appear at small bounds.
