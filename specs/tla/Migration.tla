------------------------------- MODULE Migration -------------------------------
(***************************************************************************)
(* Tests premises P3 (gap-free order across migration) and P6 ("old        *)
(* outbox entries from the previous epoch are drained before any new        *)
(* emissions ... no resets, no duplicates") against the implementation.     *)
(*                                                                         *)
(* Two facts in the code are in direct tension:                            *)
(*                                                                         *)
(*  (a) The outbox is a map keyed by COMMIT INDEX ONLY:                     *)
(*        internal/emission/outbox.go write():                             *)
(*          o.bySub[e.SubID][e.Seq.CommitIndex] = e                        *)
(*      and entries are returned ordered by commit index, EPOCH IGNORED:    *)
(*        internal/emission/outbox.go pendingSorted() (sort.Ints on ci).    *)
(*                                                                         *)
(*  (b) The notifier's skip test is EPOCH-AWARE: once it sends an entry it  *)
(*      advances sentThrough, and any later entry with a LOWER epoch is     *)
(*      skipped (forever):                                                  *)
(*        internal/emission/notifier.go processTick():                     *)
(*          if e.Seq.Epoch < lastSent.Epoch -> shouldSkip = true           *)
(*                                                                         *)
(* After a restart/migration the per-bucket commit index resets to low      *)
(* values (RAFT_ARCHITECTURE.md sec 11.1: "not persisted; lost on restart") *)
(* while the epoch counter increases (applier.go NewApplier). So the outbox  *)
(* holds OLD-epoch entries at high commit indices alongside NEW-epoch        *)
(* entries at low commit indices. pendingSorted hands the NEW low-index      *)
(* entry to the notifier first; sending it advances sentThrough to the new   *)
(* epoch; every OLD-epoch entry is then skipped forever => lost update.      *)
(* And because the map is keyed by commit index, a new-epoch entry at a      *)
(* commit index an old-epoch entry already occupies OVERWRITES it => lost    *)
(* before it is ever delivered.                                            *)
(*                                                                         *)
(* There is no EPOCH_CREATE handling / epoch-ordered drain in the emission  *)
(* applier (internal/emission/applier.go applyCommand switch), so nothing   *)
(* enforces P6's "drain previous epoch first".                             *)
(*                                                                         *)
(* CONSTANT EpochAwareOutbox switches the model between the real behavior   *)
(* (FALSE) and a fix that keys/orders the outbox by the full emit_seq        *)
(* (TRUE). With TRUE the NoLoss invariant holds -- a discriminating check.   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxDeltas,         \* total number of emissions produced across both epochs
    EpochAwareOutbox   \* FALSE = real code (key/sort by commit index);
                       \* TRUE  = fix (key/sort by full emit_seq)

Epochs == 1..2

\* An outbox/produced/delivered record is an emit_seq plus its payload id.
Rec(e, ci, d) == [e |-> e, ci |-> ci, d |-> d]

VARIABLES
    epoch,       \* current epoch (1, then 2 after the single restart)
    restarted,   \* whether the migration/restart has happened
    nextCi,      \* nextCi[e] = next commit index to assign within epoch e
    gcount,      \* global payload-id counter (distinct logical deltas)
    outbox,      \* set of pending records; at most one per key (see Write)
    sentEpoch,   \* sentThrough watermark: epoch
    sentCi,      \* sentThrough watermark: commit index
    produced,    \* set of every record ever written to the outbox
    delivered    \* set of records actually delivered to the client

vars == <<epoch, restarted, nextCi, gcount, outbox, sentEpoch, sentCi, produced, delivered>>

Init ==
    /\ epoch     = 1
    /\ restarted = FALSE
    /\ nextCi    = [e \in Epochs |-> 1]
    /\ gcount    = 0
    /\ outbox    = {}
    /\ sentEpoch = 0
    /\ sentCi    = 0
    /\ produced  = {}
    /\ delivered = {}

\* Records sharing the outbox "key". Real code keys by commit index only, so a
\* later write at the same commit index displaces the earlier one. The fix keys
\* by the full (epoch, commit index).
SameKey(x, e, ci) ==
    IF EpochAwareOutbox THEN (x.e = e /\ x.ci = ci)
                        ELSE (x.ci = ci)

\* A committed delta is turned into an OUTBOX_WRITE under the current epoch.
Produce ==
    /\ gcount < MaxDeltas
    /\ LET ci == nextCi[epoch]
           d  == gcount + 1
           r  == Rec(epoch, ci, d)
       IN /\ outbox'   = { x \in outbox : ~ SameKey(x, epoch, ci) } \cup { r }
          /\ produced' = produced \cup { r }
          /\ nextCi'   = [nextCi EXCEPT ![epoch] = @ + 1]
          /\ gcount'   = d
    /\ UNCHANGED <<epoch, restarted, sentEpoch, sentCi, delivered>>

\* The migration / restart: epoch advances; the per-bucket commit index for the
\* new epoch starts low (nextCi[2] is still 1). The notifier is recreated, so its
\* sentThrough watermark resets. The durable outbox survives.
Restart ==
    /\ ~restarted
    /\ epoch = 1
    /\ epoch'     = 2
    /\ restarted' = TRUE
    /\ sentEpoch' = 0
    /\ sentCi'    = 0
    /\ UNCHANGED <<nextCi, gcount, outbox, produced, delivered>>

\* The notifier's order over pending entries: commit index only (real) or full
\* emit_seq (fix).
Before(x, y) ==
    IF EpochAwareOutbox
      THEN (x.e < y.e) \/ (x.e = y.e /\ x.ci <= y.ci)
      ELSE (x.ci <= y.ci)

\* processTick skip test (epoch-aware in BOTH variants -- this is the code).
Eligible(r) ==
    /\ ~ (r.e < sentEpoch)
    /\ ~ (r.e = sentEpoch /\ r.ci <= sentCi)

\* Deliver the first eligible pending entry in the notifier's order, then ack ->
\* purge it. (Resends are permitted by the contract; loss is what we check.)
Deliver ==
    LET E == { r \in outbox : Eligible(r) } IN
        /\ E # {}
        /\ LET r == CHOOSE x \in E : \A y \in E : Before(x, y) IN
              /\ delivered' = delivered \cup { Rec(r.e, r.ci, r.d) }
              /\ outbox'    = outbox \ { r }
              /\ sentEpoch' = r.e
              /\ sentCi'    = r.ci
        /\ UNCHANGED <<epoch, restarted, nextCi, gcount, produced>>

Next == Produce \/ Restart \/ Deliver

Spec == Init /\ [][Next]_vars

\* Is record r still present and unmodified in the outbox?
InOutbox(r) == \E x \in outbox : x.e = r.e /\ x.ci = r.ci /\ x.d = r.d

(***************************************************************************)
(* P3/P6: no committed delta is lost. Every produced record is either       *)
(* already delivered, or still intact in the outbox AND not stranded behind  *)
(* a higher-epoch watermark (i.e. it can still be delivered).               *)
(***************************************************************************)
NoLoss ==
    \A r \in produced :
        \/ r \in delivered
        \/ (InOutbox(r) /\ r.e >= sentEpoch)

TypeOK ==
    /\ epoch \in Epochs
    /\ sentEpoch \in 0..2
    /\ gcount \in 0..MaxDeltas
=============================================================================
