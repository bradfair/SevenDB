------------------------------- MODULE Rebind -------------------------------
(***************************************************************************)
(* Tests premise P3/P4 (gap-free, no lost update) for a SAME-EPOCH          *)
(* disconnect -> reconnect, where the only thing that can strand an entry    *)
(* is the notifier's sentThrough watermark (no epoch effects -- this is what *)
(* makes it distinct from Migration.tla).                                   *)
(*                                                                         *)
(* The notifier skips an entry whose commit index is <= sentThrough         *)
(* (same epoch). Crucially, the resume floor can only ADD a skip, never     *)
(* override the sentThrough skip:                                           *)
(*   internal/emission/notifier.go processTick():                          *)
(*     if e.Seq.CommitIndex <= lastSent.CommitIndex: shouldSkip = true      *)
(*     if shouldSkip: continue                                              *)
(*     if resumeIdx > 0 && e.Seq.CommitIndex < resumeIdx: continue          *)
(* So the ONLY way to re-send an entry at or below sentThrough is to CLEAR   *)
(* sentThrough.                                                            *)
(*                                                                         *)
(* sentThrough is cleared in exactly two places, and both can fail to fire  *)
(* on a fast reconnect:                                                     *)
(*                                                                         *)
(*  (1) On disconnect, ClearEmissionWatermarksForClient(clientID)           *)
(*      (internal/server/ironhawk/main.go:176) clears it -- BUT only "if we  *)
(*      successfully cleaned up the thread. If ... a new thread has already  *)
(*      taken over, we should NOT clear watermarks" (main.go:171-177). On a  *)
(*      fast reconnect the new thread takes over first, so the clear is      *)
(*      SKIPPED.                                                            *)
(*                                                                         *)
(*  (2) On reconnect, SetResumeFrom(sub, nextIdx) clears sentThrough -- BUT  *)
(*      only on the nextIdx != 0 path; nextIdx == 0 early-returns without    *)
(*      clearing (internal/emission/notifier.go:157-167). And the production *)
(*      reconnect ALWAYS returns next = 0 (see Reconnect.tla / H1), so this  *)
(*      clear never happens via the command path.                          *)
(*                                                                         *)
(* The client supplies a STABLE client id (internal/server/ironhawk/        *)
(* iothread.go:141-142 `t.ClientID = _c.ClientID`; README EMITRECONNECT       *)
(* example "client123:..."), so the reconnect sub id equals the old one and  *)
(* RebindByFingerprint early-returns (outbox.go:335) without touching        *)
(* sentThrough.                                                            *)
(*                                                                         *)
(* Net: fast reconnect (clear skipped) + next=0 reconnect (clear skipped)    *)
(* leaves a high sentThrough, and any committed entry the client had not yet  *)
(* processed (its in-flight copy lost on disconnect) is skipped forever.     *)
(*                                                                         *)
(* CONSTANT CorrectReconnect switches between the real behavior (FALSE) and  *)
(* a fix that clears sentThrough on reconnect (TRUE).                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxIdx,           \* number of emissions that can be committed
    CorrectReconnect  \* FALSE = real code (next=0, sentThrough untouched)
                      \* TRUE  = fix (reconnect clears sentThrough)

VARIABLES
    committed,    \* highest committed emission commit index
    sentThrough,  \* notifier sentThrough watermark (single epoch)
    processed,    \* client's durable processed watermark (in order)
    inflight,     \* indices sent to the currently-connected client, unprocessed
    resume,       \* resumeFrom floor (0 = none)
    connected     \* client connection state

vars == <<committed, sentThrough, processed, inflight, resume, connected>>

Init ==
    /\ committed   = 0
    /\ sentThrough = 0
    /\ processed   = 0
    /\ inflight    = {}
    /\ resume      = 0
    /\ connected   = TRUE

Commit ==
    /\ committed < MaxIdx
    /\ committed' = committed + 1
    /\ UNCHANGED <<sentThrough, processed, inflight, resume, connected>>

\* The notifier sends the lowest entry that is past sentThrough and not below the
\* resume floor; resume can never rescue an entry already at/below sentThrough.
SendIdx == IF resume > sentThrough + 1 THEN resume ELSE sentThrough + 1

Send ==
    /\ connected
    /\ SendIdx <= committed
    /\ sentThrough' = SendIdx
    /\ inflight'    = inflight \cup {SendIdx}
    /\ UNCHANGED <<committed, processed, resume, connected>>

\* The client processes the next in-order entry it has actually received.
ClientProcess ==
    /\ connected
    /\ (processed + 1) \in inflight
    /\ processed' = processed + 1
    /\ inflight'  = inflight \ {processed + 1}
    /\ UNCHANGED <<committed, sentThrough, resume, connected>>

\* Disconnect drops all in-flight (un-acked) entries. The disconnect-time clear
\* of sentThrough either fires or is SKIPPED by the fast-reconnect race
\* (main.go:171-177) -- modeled nondeterministically.
Disconnect ==
    /\ connected
    /\ connected' = FALSE
    /\ inflight'  = {}
    /\ (sentThrough' = 0 \/ sentThrough' = sentThrough)
    /\ UNCHANGED <<committed, processed, resume>>

\* Reconnect (same stable client id, same epoch). Real code: next=0 path leaves
\* sentThrough untouched and only deletes resume. Fix: clear sentThrough so
\* unprocessed entries can be re-sent.
Reconnect ==
    /\ ~connected
    /\ connected' = TRUE
    /\ IF CorrectReconnect
         THEN /\ sentThrough' = processed
              /\ resume'       = 0
         ELSE /\ sentThrough' = sentThrough
              /\ resume'       = 0
    /\ UNCHANGED <<committed, processed, inflight>>

Next == Commit \/ Send \/ ClientProcess \/ Disconnect \/ Reconnect

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* An entry is STUCK if, while connected, it is committed and unprocessed,  *)
(* is not currently in flight (so it will not be processed), and sits at or  *)
(* below sentThrough (so it can never be re-sent) -- a permanent lost update.*)
(***************************************************************************)
Stuck(ci) ==
    /\ ci > processed
    /\ ci \notin inflight
    /\ ci <= sentThrough

GapFree == connected => \A ci \in 1..committed : ~ Stuck(ci)

TypeOK ==
    /\ committed \in 0..MaxIdx
    /\ sentThrough \in 0..MaxIdx
    /\ processed \in 0..MaxIdx
    /\ resume \in 0..MaxIdx
=============================================================================
