# Adversarial review of the TLA+ findings

A TLA+ counterexample is only meaningful if the model is faithful to the code —
otherwise it just proves a bug that was written into the model. To guard against
that, each of the five findings was handed to an independent reviewer whose
explicit mandate was to **refute** it by reading the actual Go code, treating the
finding's framing as untrusted. A finding is only credible if a hostile reading
of the code cannot break it.

## Outcome: none refuted

| Finding | Spec | Reviewer verdict |
|---|---|---|
| P1 — outbox resurrection ⇒ effective-once violated | `EmissionContract.tla` | **AGREE** (could not refute) |
| P5 — reconnect always returns `OK, next=0` | `Reconnect.tla` | **AGREE — empirically confirmed** |
| H2/H3 — cross-epoch outbox loss (overwrite + strand) | `Migration.tla` | **AGREE** (could not refute) |
| H5 — compaction prunes un-acked emissions | `Compaction.tla` | **AGREE** (could not refute) |
| H4 — same-epoch lost update across fast reconnect | `Rebind.tla` | **PARTIALLY AGREE** (real, precondition-gated) |

That the reviewers found independent evidence (below), and that the one finding
whose reachability was least certain came back *qualified* rather than rubber-
stamped, indicates the reviews were genuinely critical.

## Independent evidence the reviewers found (beyond the models)

- **P5 is confirmed at runtime, not just in the model.** The reviewer found and
  ran the repository's own e2e test
  `tests/commands/ironhawk/emission_reconnect_e2e_test.go`
  (`TestEmissionContract_Reconnect_StaleSequence`), which **fails**:
  `expected STALE_SEQUENCE, got "OK 0"`, with the server log showing the live
  wall-clock epoch vs. the request's hardcoded epoch `0`. This is the strongest
  corroboration available — the bug is observable through the real command path.

- **P1**: `Config.Applied` is never set anywhere in `internal/raft`, and the
  apply loop has no dedup guard against the restored `lastAppliedIndex`
  (`types.go` `processReady` / `ManualProcessNextReady`). The existing restart
  test only asserts `LastAppliedIndex` does not regress — re-delivery would not
  regress it, so the test passes with the bug present.

- **H5**: a grep of `internal/raft` for any ack / safety-point term returns zero
  matches; the only prune floor is follower *replication* match index
  (`minFollowerMatchIndex`), not client acks. The manual compaction path
  (`types.go:1732`) has no floor at all.

- **H2/H3**: the per-bucket commit index is rebuilt from a fresh map on restart
  (`types.go`), confirmed by `RAFT_ARCHITECTURE.md` §11.1, so new-epoch entries
  collide with old-epoch commit indices on the normal restart path.

- **H4**: the client id is application-supplied and reused across reconnects
  (`cmd_handshake.go`; the reconnect benches/e2e all reuse the same id), so
  `RebindByFingerprint` early-returns and leaves `sentThrough` intact. Both
  watermark-clearing safety nets are defeated (the disconnect-time clear loses
  the `main.go:171-177` race; the reconnect-time clear is on the `next != 0`
  path, which production never takes).

## Recorded preconditions (honest scoping, not refutations)

- **P1, H2/H3** require the production **restart-with-persistence** path (etcd
  engine). The default `stub` engine and `DisablePersistence` test mode do not
  re-apply the committed log on restart — which is precisely why the existing
  tests do not catch these.

- **P1 blast radius depends on snapshot config.** `snapshotThreshold` is wired
  from config (`RaftSnapshotThresholdEntries`, default **10000**) when config is
  loaded (`types.go:1147`), and is **0** otherwise (`types.go:1150`). With
  snapshots off, the entire committed log re-delivers on restart; with snapshots
  on, everything above the last snapshot re-delivers. The bug exists in both
  postures; only the size of the re-delivery window changes. (This also resolves
  the apparent tension between the P1 and H5 reviews: H5's snapshot-prune path
  only fires when snapshots are enabled, which is the production default.)

- **H4** is an *intra-process* fast-reconnect bug: it requires no restart
  between disconnect and reconnect (so the in-memory epoch is unchanged and the
  stranded entry shares the stale `sentThrough`'s epoch), a reused client id,
  and the cleanup race being won by the new thread. Across a restart the epoch
  changes and the in-memory `sentThrough` is gone, so the entry would re-send —
  no gap. This matches the `Rebind.tla` "same-epoch" framing.

## Round 2: auditing the MODELS (not the bugs)

A second adversarial pass targeted the TLA+ specs themselves: are they faithful
to the code, or do they bake in their conclusions (vacuous/tautological
invariants, false-positive invariants that flag benign states, rigged
`Init`/`Next`, strawman "fix" variants)? Each reviewer had TLC and was
encouraged to mutate copies of the spec and re-run.

| Spec | Model verdict | Notes |
|---|---|---|
| `EmissionContract.tla` | FAITHFUL | Reviewer ran 3 TLC mutation experiments; confirmed the violation is caused specifically by the `(epoch,ci)` idempotency key + epoch bump, and that adding old-record replay still violates (the omission is not load-bearing). |
| `Reconnect.tla` | FAITHFUL core, **defect found** | `ReconnectSound` is fair and runtime-corroborated, but the original `FixHolds` was **tautological** (`FixedStatus == SpecStatus`). |
| `Migration.tla` | FAITHFUL | Reviewer decoupled the two fix switches and showed each bug (overwrite, strand) fails independently and only fixing BOTH passes — rules out a rigged toggle. |
| `Compaction.tla` | FAITHFUL | Reviewer stress-tested the strongest refutation (omitted follower floor) and found it does not rescue the code: the floor runs after the destructive prune, governs only the WAL-segment cleanup, and tracks follower replication, not client acks. |
| `Rebind.tla` | FAITHFUL | Reviewer initially attacked with `next=processed+1`, discovered the real code uses `next=0`, and retracted its own strawman. `GapFree` confirmed not a false positive (the stranded state is genuinely unrecoverable). |

### Defects found in the specs, and the fixes applied

1. **`Reconnect.tla` — tautological fix variant.** `FixedStatus`/`FixedNext` were
   defined as literally `== SpecStatus`/`SpecNext`, so `FixHolds` was true by
   reflexivity and proved nothing. Fixed by introducing `DecisionStatus(reqEpoch,
   …)` that models the real epoch-mismatch guard; production threads `reqEpoch=0`,
   the fix threads `reqEpoch=ServerEpoch`. `FixHolds` now passes *through* the
   guard (40 states), not by definition. `ReconnectSound` still fails as before.

2. **`EmissionContract.tla` — no discriminating fix variant.** The cfg had no
   switch, so non-vacuity was never self-demonstrated. Added CONSTANT
   `IdempotentEmit`: FALSE = real (idempotency key `(epoch, ci)`), TRUE = fix
   (idempotency key = source `ci`). TLC: FALSE violates `EffectiveOnce`, TRUE
   passes (10 states). The model now proves it discriminates.

Note (charitable abstraction, left as-is): `EmissionContract.tla` models a
client that de-dups on `emit_seq`, but no such client de-dup exists in this repo
(`emission_bridge.go` ships the raw seq; server-side dedups are keyed on the same
lex `(epoch,ci)` and also fail to suppress the resurrected entry). The model thus
gives the system the benefit of the doubt and *still* violates effective-once —
reality is worse, not better.

## Why the existing test suite misses all five

Each finding lives in a fault/recovery interleaving the current tests do not
construct: restart-with-persistence + epoch rotation (P1, H2/H3), a nonzero live
epoch at reconnect (P5 — unit tests leave `currentEpoch` at 0, so the buggy
branch is never taken), volume-triggered compaction of un-acked entries (H5), and
stable-id + same-epoch + sent-but-unacked-then-disconnect (H4 — the e2e test uses
a stable id but only asserts a *new* higher-index emission arrives, which is
never the one that gets stranded). This is the class of bug exhaustive state
enumeration is built to find and example-based tests are not.
