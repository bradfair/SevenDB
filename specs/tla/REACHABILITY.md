# Reachability: executable Go tests for each TLA+ finding

Each TLA+ finding now has an executable Go test that reproduces it against the
real code. The tests are **characterization tests**: they pin the *current
(buggy)* behavior so the suite stays green, and each documents (in a
`CONVERT-ON-FIX` comment) the design-correct assertion to flip once the bug is
fixed. No production code is modified.

Files:
- `internal/emission/reachability_bug_test.go` — unit level (Manager / Notifier)
- `internal/emission/integration_reachability_test.go` — integration level
  (real single-node etcd raft node with persistence, driven through the Applier)

Run:
```sh
go test ./internal/emission/ -run Reachability -v          # all
go test ./internal/emission/ -run Reachability -short      # unit only (skips raft restart/snapshot)
```

## Reachability map

| Finding | Test | Level | Cost | Reproduces |
|---|---|---|---|---|
| P5 reconnect → OK/next=0 | `TestReachability_P5_ReconnectAlwaysOKNextZero` | unit | trivial | Manager.Reconnect with epoch-0 request + nonzero live epoch returns OK/next=0; control with matching epoch returns STALE_SEQUENCE |
| H2 cross-epoch overwrite | `TestReachability_H2_CrossEpochOverwriteLoss` | unit | trivial | second write at same commit index, new epoch, overwrites the first in the commit-index-keyed map |
| H3 cross-epoch strand | `TestReachability_H3_CrossEpochStrandLoss` | unit | trivial | notifier sends new-epoch low-index entry first, then permanently skips the old-epoch higher-index entry |
| H4 same-epoch reconnect gap | `TestReachability_H4_SameEpochReconnectGap` | unit | trivial | sent-but-unacked entry stranded after `SetResumeFrom(sub,0)` leaves `sentThrough` uncleared |
| P1 resurrection (mechanism) | `TestReachability_P1_OutboxResurrectionMechanism` | unit | trivial | purged delta re-written under a higher epoch is delivered a second time |
| P1 resurrection (end-to-end) | `TestReachabilityIntegration_P1_RestartResurrection` | integration | real raft restart | a real restart re-applies the committed `DATA_EVENT`; the leader re-proposes `OUTBOX_WRITE` under a new wall-clock epoch |
| H5 compaction ignores acks | `TestReachabilityIntegration_H5_CompactionIgnoresUnackedOutbox` | integration | real raft snapshot | a volume-triggered snapshot/compaction fires while un-acked outbox entries are still pending |

**Cheap and fully reachable at unit level:** P5, H2, H3, H4, and the P1
*mechanism*. These need only the `emission` package (`Manager`, `Notifier`,
`MemorySender`, `TestTickOnce`) and run in microseconds.

**Reachable only with raft plumbing:** the P1 *end-to-end* trigger and H5.
A single-node etcd node (`Engine:"etcd"` + a `SimulatedClock`) is enough — no
multi-node harness required — but they elect a leader and persist to disk.

## Two findings the reachability tests surfaced (beyond the specs)

These refine the earlier confidence ordering and are worth recording:

1. **P1 end-to-end is timing-dependent (racy), not guaranteed on every restart.**
   The resurrection re-proposal is gated by `IsLeader()` *at apply time*. On
   restart, etcd re-delivers the committed log early; if the Applier consumes the
   replayed `DATA_EVENT` *before* the node wins election, `ProposeAndWait` returns
   `NotLeaderError` and no resurrection occurs. If it consumes it *while leader*,
   the resurrection fires. The integration test forces the triggering
   interleaving (elect, then start the applier so the buffered replay is consumed
   while leader) to make it deterministic; with a continuously-running applier the
   outcome is a race. So P1's resurrection is *reachable* but not *inevitable* on
   a given restart.

2. **Two bugs partially cancel: the epoch-blind purge (H2) can mask P1.**
   If the client had acked before the restart, the log also replays an
   `OUTBOX_PURGE`. Because purge is keyed by commit index only (H2), and the
   resurrected `OUTBOX_WRITE` reuses the same commit index (the per-bucket index
   is recomputed identically on replay), the re-applied purge removes the
   resurrected entry too. So the client-visible *double effect* additionally
   requires the resurrected entry to survive purge (e.g. mismatched commit
   indices, or an un-acked-but-already-processed delta as in the
   crash-after-send-before-ack window). The resurrection itself is reachable; its
   escalation to a client double-effect is conditional.

## What is NOT reproduced as a test, and why

- **H6 (single-emitter / lease)** has no test: as the adversarial review noted,
  raft prevents two committing leaders and a stale double-emit carries the same
  `emit_seq` (dedup-safe), so there is no confirmed divergent-identity path to
  reproduce. It remains open pending such a path.
- The **client-visible double-effect** for P1 is not asserted end-to-end (see
  finding 2 above); the tests assert the resurrection (re-emission under a new
  epoch), which is the reachable, unconditional part.
