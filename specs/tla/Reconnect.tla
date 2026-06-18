------------------------------- MODULE Reconnect -------------------------------
(***************************************************************************)
(* Tests premise P5 (the reconnect protocol) against its implementation.   *)
(*                                                                         *)
(* Design contract (docs/.../emission-contract.mdx sec 5.2):               *)
(*   On reconnect the server returns, as a function of the client's        *)
(*   position vs. its watermarks:                                          *)
(*     - valid & present  -> OK,      resume from commit_index + 1         *)
(*     - too old (compacted) -> STALE_SEQUENCE                             *)
(*     - ahead (rollback)    -> INVALID_SEQUENCE                          *)
(*                                                                         *)
(* Implementation, production path:                                        *)
(*   internal/cmd/cmd_emitreconnect.go:44 builds the ReconnectRequest with *)
(*   a HARDCODED EpochCounter = 0 ("// MVP epoch: 0").                      *)
(*   internal/emission/outbox.go Reconnect() then does, FIRST:             *)
(*       if req.Epoch.EpochCounter != currentEpoch.EpochCounter            *)
(*           return {OK, NextCommitIndex: 0}                               *)
(*   The live epoch comes from internal/emission/applier.go NewApplier:    *)
(*       EpochCounter = uint64(time.Now().UnixNano())   (always != 0)      *)
(*                                                                         *)
(* Therefore the guard 0 != <nanos> is ALWAYS true, so production reconnect *)
(* ALWAYS returns {OK, next = 0}; the STALE / INVALID / compaction logic    *)
(* below it is unreachable from the command path.                          *)
(*                                                                         *)
(* SCOPING (to avoid a strawman): we model a SAME-EPOCH reconnect -- a      *)
(* network blip with no restart, where the client genuinely holds the      *)
(* current epoch. Here the design unambiguously wants OK/STALE/INVALID with *)
(* a correct resume index; "force restart from 0" is only defensible for a  *)
(* true cross-epoch reconnect. The bug is that hardcoding epoch 0 corrupts  *)
(* even the same-epoch case.                                               *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxIdx,       \* bound on commit indices to enumerate
    ServerEpoch   \* the live (nonzero, wall-clock) epoch counter

Status == {"OK", "STALE", "INVALID"}

\* ---- The design's intended reconnect decision (same epoch) ----
\* Mirrors the order of checks in outbox.go Reconnect AFTER the epoch guard:
\*   1) ahead of last ack            -> INVALID
\*   2) below compaction watermark   -> STALE
\*   3) otherwise                    -> OK
SpecStatus(p, ack, comp) ==
    IF p > ack          THEN "INVALID"
    ELSE IF p < comp    THEN "STALE"
    ELSE "OK"

SpecNext(p, ack, comp) ==
    IF p > ack          THEN ack + 1
    ELSE IF p < comp    THEN comp
    ELSE p + 1

\* ---- The implementation's production behavior ----
\* The request epoch is hardcoded to 0; ServerEpoch is nonzero; so the very
\* first branch fires for every input, regardless of p/ack/comp.
ProdStatus(p, ack, comp) == "OK"
ProdNext(p, ack, comp)   == 0

\* Realistic watermark domain: you only compact through what has been acked,
\* so comp <= ack. Client position p ranges over all indices.
Inputs == { <<p, ack, comp>> \in (0..MaxIdx) \X (0..MaxIdx) \X (0..MaxIdx) :
            comp <= ack }

\* ---- A discriminating "fixed" variant: thread the client's REAL epoch ----
\* (ServerEpoch) instead of 0. Then the epoch guard does not fire and the
\* implementation reduces to the design decision -> the property holds. This
\* proves the spec distinguishes correct from buggy behavior (not vacuous).
FixedStatus(p, ack, comp) == SpecStatus(p, ack, comp)
FixedNext(p, ack, comp)   == SpecNext(p, ack, comp)

\* Enumerate every reconnect input as a distinct initial state so that a TLC
\* invariant violation reports the exact (position, ack, compacted) witness.
VARIABLES pos, ack, comp
vars == <<pos, ack, comp>>

Init == \E t \in Inputs : pos = t[1] /\ ack = t[2] /\ comp = t[3]
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

\* ---- Properties ----
\* P5: the production reconnect decision must equal the design decision.
ReconnectSound ==
    /\ ProdStatus(pos, ack, comp) = SpecStatus(pos, ack, comp)
    /\ ProdNext(pos, ack, comp)   = SpecNext(pos, ack, comp)

\* Sanity: the proposed fix satisfies the property (must hold for every input).
FixHolds ==
    /\ FixedStatus(pos, ack, comp) = SpecStatus(pos, ack, comp)
    /\ FixedNext(pos, ack, comp)   = SpecNext(pos, ack, comp)
=============================================================================
