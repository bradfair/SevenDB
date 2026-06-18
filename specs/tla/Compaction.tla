------------------------------- MODULE Compaction -------------------------------
(***************************************************************************)
(* Tests premise P8 (compaction safety) and, through it, P4 (durable        *)
(* outbox => no loss on failover).                                          *)
(*                                                                         *)
(* Design contract (docs/.../emission-contract.mdx sec 8):                  *)
(*   safety_point = min(oldest_cold_replica_checkpoint,                     *)
(*                      min_active_client_ack,                             *)
(*                      migration_hold_point)                              *)
(*   "The system will never compact beyond safety_point."                  *)
(*                                                                         *)
(* Implementation:                                                          *)
(*   internal/raft/types.go:1461  snapshot triggers purely on volume:       *)
(*     committedSinceSnap >= snapshotThreshold                             *)
(*   internal/raft/types.go:1463  CreateSnapshot(lastAppliedIndex, cs, nil) *)
(*     -- the snapshot DATA is nil, so NO application/outbox state is        *)
(*        captured in the snapshot.                                        *)
(*   internal/raft/types.go:1469  Compact(snapIndex) then PruneEntries(...) *)
(*     remove raft log entries below the applied index.                    *)
(*                                                                         *)
(* The outbox is reconstructed only by replaying OUTBOX_WRITE / OUTBOX_PURGE *)
(* log records (internal/emission/applier.go). Once those records are        *)
(* pruned and the snapshot stores no outbox state, any un-acked emission     *)
(* below the snapshot index is gone after restart/failover. Nothing ties     *)
(* the compaction point to min client ack, so P8 is not enforced.           *)
(*                                                                         *)
(* CONSTANT AckAwareCompaction switches between the real behavior (FALSE,    *)
(* compact at applied index) and a fix (TRUE, compact at min(applied, ack)). *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxIndex,           \* bound on the number of committed emissions
    SnapThreshold,      \* committedSinceSnap trigger (= snapshotThreshold)
    AckAwareCompaction  \* FALSE = real code; TRUE = compact no further than ack

VARIABLES
    applied,    \* highest committed/applied emission log index
    ackWM,      \* client ack watermark: all emissions <= ackWM are acked
    sinceSnap,  \* committedSinceSnap counter
    pruned      \* highest log index pruned/compacted away (lost unless acked)

vars == <<applied, ackWM, sinceSnap, pruned>>

Init ==
    /\ applied   = 0
    /\ ackWM     = 0
    /\ sinceSnap = 0
    /\ pruned    = 0

\* A new emission (OUTBOX_WRITE) is committed.
Commit ==
    /\ applied < MaxIndex
    /\ applied'   = applied + 1
    /\ sinceSnap' = sinceSnap + 1
    /\ UNCHANGED <<ackWM, pruned>>

\* The client acks the next emission in order (advances the ack watermark).
Ack ==
    /\ ackWM < applied
    /\ ackWM' = ackWM + 1
    /\ UNCHANGED <<applied, sinceSnap, pruned>>

\* Snapshot+compaction. Real code compacts at the applied index regardless of
\* acks; the fix would clamp the compaction point to the ack watermark.
CompactPoint == IF AckAwareCompaction THEN (IF applied < ackWM THEN applied ELSE ackWM)
                                      ELSE applied

Snapshot ==
    /\ sinceSnap >= SnapThreshold
    /\ pruned'    = CompactPoint
    /\ sinceSnap' = 0
    /\ UNCHANGED <<applied, ackWM>>

Next == Commit \/ Ack \/ Snapshot

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* P8: never compact beyond the client ack watermark. An emission at an     *)
(* index > ackWM is un-acked; pruning it (with nil snapshot data) loses it.  *)
(***************************************************************************)
CompactSafe == pruned <= ackWM

TypeOK ==
    /\ applied \in 0..MaxIndex
    /\ ackWM \in 0..MaxIndex
    /\ pruned \in 0..MaxIndex
=============================================================================
