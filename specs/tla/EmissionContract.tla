-------------------------- MODULE EmissionContract --------------------------
(***************************************************************************)
(* A top-down TLA+ model of SevenDB's "Emission Contract" premise:        *)
(*                                                                         *)
(*   "effective-once delivery -- every logical change is reflected to      *)
(*    clients exactly once in effect, even in the presence of crashes,     *)
(*    reconnections, or migration."                                        *)
(*        -- docs/src/content/docs/architecture/emission-contract.mdx      *)
(*                                                                         *)
(* The model encodes the ACTUAL transition relation implemented in the     *)
(* code, not an idealized version, so that TLC checks the premise against  *)
(* the implementation's behavior.                                          *)
(*                                                                         *)
(* Code mapping (the assumptions that make this faithful):                 *)
(*                                                                         *)
(*  - emit_seq = (epoch_counter, commit_index), compared lexicographically *)
(*       internal/emission/types.go (EmitSeq), outbox.go ValidateAck.      *)
(*                                                                         *)
(*  - The applier turns each committed DATA_EVENT into an OUTBOX_WRITE and  *)
(*    proposes it back into raft, guarded only by IsLeader -- there is NO  *)
(*    check that this DATA_EVENT was already emitted / acked / purged:      *)
(*       internal/emission/applier.go  applyCommand, case "DATA_EVENT".    *)
(*                                                                         *)
(*  - Each (re)start mints a NEW epoch counter from wall-clock time:        *)
(*       internal/emission/applier.go  NewApplier:                          *)
(*         epoch.EpochCounter = uint64(time.Now().UnixNano())              *)
(*    so every restart strictly increases the epoch.                       *)
(*                                                                         *)
(*  - On restart the raft node is created WITHOUT Config.Applied set:       *)
(*       internal/raft/types.go:998 etcdraft.Config{...} (no Applied)      *)
(*    so etcd/raft re-delivers every committed entry above the snapshot,   *)
(*    the applier re-processes old DATA_EVENTs, and (being leader) it       *)
(*    re-proposes OUTBOX_WRITE for them -- now under the new epoch.         *)
(*                                                                         *)
(*  - The outbox is durable (rebuilt from the replicated log); purge        *)
(*    removes entries by commit index only:                                 *)
(*       internal/emission/outbox.go purge(sub, upTo.CommitIndex).          *)
(*                                                                         *)
(*  - The client de-duplicates purely on emit_seq order ("discard any      *)
(*    message with emit_seq <= last_ack"): emission-contract.mdx sec 2/9.   *)
(*                                                                         *)
(* Running TLC on this spec finds a short trace in which a single source    *)
(* delta is delivered to the client TWICE in effect -- once under epoch 1   *)
(* and again, resurrected from the durable log, under epoch 2 after a       *)
(* restart -- violating the effective-once premise.                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    NumDeltas,   \* number of source DATA events committed to the raft log
    MaxEpoch     \* bound on the number of (re)starts (epoch counter ceiling)

\* A sequence number is a record [e |-> epoch, ci |-> commitIndex].
LexLeq(a, b)  == \/ a.e < b.e
                 \/ (a.e = b.e /\ a.ci <= b.ci)
LexLess(a, b) == LexLeq(a, b) /\ a # b

CI == 1..NumDeltas

VARIABLES
    epoch,       \* current epoch counter (a fresh, larger value after each restart)
    produced,    \* set of source commit indices committed to the raft log so far
    outbox,      \* set of pending (unpurged) seqs   {[e,ci]}
    purged,      \* set of seqs already purged        {[e,ci]}
    owritten,    \* set of seqs ever OUTBOX_WRITTEN   {[e,ci]}  (idempotency key)
    clientLast,  \* highest seq the client has processed (lex); [e|->0,ci|->0] initially
    effects      \* effects[ci] = # of times the client applied delta ci (must stay <= 1)

vars == <<epoch, produced, outbox, purged, owritten, clientLast, effects>>

Init ==
    /\ epoch      = 1
    /\ produced   = {}
    /\ outbox     = {}
    /\ purged     = {}
    /\ owritten   = {}
    /\ clientLast = [e |-> 0, ci |-> 0]
    /\ effects    = [c \in CI |-> 0]

\* A source DATA_EVENT is committed to the (durable) raft log, in index order.
Produce ==
    \E ci \in CI :
        /\ ci \notin produced
        /\ \A j \in CI : j < ci => j \in produced
        /\ produced' = produced \cup {ci}
        /\ UNCHANGED <<epoch, outbox, purged, owritten, clientLast, effects>>

\* Leader applies a committed DATA_EVENT and proposes OUTBOX_WRITE under the
\* CURRENT epoch. The only guard in the code is "have I already produced this
\* exact (epoch,ci) OUTBOX_WRITE?" -- so after a restart bumps the epoch this
\* re-fires for an already-delivered, already-purged source delta.
LeaderEmit ==
    \E ci \in produced :
        LET seq == [e |-> epoch, ci |-> ci] IN
            /\ seq \notin owritten
            /\ owritten' = owritten \cup {seq}
            /\ outbox'   = outbox   \cup {seq}
            /\ UNCHANGED <<epoch, produced, purged, clientLast, effects>>

\* The notifier delivers a pending entry; the client de-dups on emit_seq and,
\* once processed, acks -> the entry is purged from the durable outbox.
Deliver ==
    \E seq \in outbox :
        /\ IF LexLess(clientLast, seq)
              THEN /\ effects'    = [effects EXCEPT ![seq.ci] = @ + 1]
                   /\ clientLast' = seq
              ELSE UNCHANGED <<effects, clientLast>>
        /\ outbox' = outbox \ {seq}
        /\ purged' = purged \cup {seq}
        /\ UNCHANGED <<epoch, produced, owritten>>

\* Node restart: the applier mints a new, strictly-greater epoch. The durable
\* outbox/purge/owritten state survives (it is part of the replicated log).
Restart ==
    /\ epoch < MaxEpoch
    /\ epoch' = epoch + 1
    /\ UNCHANGED <<produced, outbox, purged, owritten, clientLast, effects>>

Next == Produce \/ LeaderEmit \/ Deliver \/ Restart

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* The premise, as an invariant: no logical delta is applied twice.        *)
(***************************************************************************)
EffectiveOnce == \A ci \in CI : effects[ci] <= 1

TypeOK ==
    /\ epoch \in 1..MaxEpoch
    /\ produced \subseteq CI
    /\ effects \in [CI -> 0..MaxEpoch]
=============================================================================
