package emission_test

// Characterization tests that EMPIRICALLY REPRODUCE the bugs identified by the
// TLA+ specs in specs/tla. They are written to PIN THE CURRENT (BUGGY) BEHAVIOR
// so the suite stays green while proving each issue is reachable in real code.
//
// Each test documents (a) the design contract that SHOULD hold, (b) the current
// behavior it actually observes, and (c) how to convert it into a regression
// test once the bug is fixed (invert the assertion at the marked line).
//
// No production code is modified. These tests assert reachability only.

import (
	"context"
	"testing"

	"github.com/sevenDatabase/SevenDB/internal/emission"
)

// countDeltas returns how many delivered events carried the given payload.
func countDeltas(events []*emission.DataEvent, payload string) int {
	n := 0
	for _, e := range events {
		if string(e.Delta) == payload {
			n++
		}
	}
	return n
}

// P5 — Reconnect always returns OK/next=0 on the production command path.
//
// Design contract (docs/.../emission-contract.mdx §5.2): a reconnect whose
// position is below the compaction watermark must return STALE_SEQUENCE.
// Production: cmd_emitreconnect.go:44 builds the request with EpochCounter=0,
// while the live epoch (applier.go NewApplier) is a nonzero wall-clock value,
// so outbox.go Reconnect()'s first branch (epoch mismatch) always fires and
// returns {OK, next:0}, making STALE/INVALID unreachable.
func TestReachability_P5_ReconnectAlwaysOKNextZero(t *testing.T) {
	mgr := emission.NewManager("bkt")

	liveEpoch := emission.EpochID{BucketUUID: "bkt", EpochCounter: 1781749266477683529}
	mgr.SetCurrentEpoch(liveEpoch)

	sub := "client123:42"
	// Client acked through commit index 5; outbox compacted through 5.
	mgr.ValidateAck(sub, emission.EmitSeq{Epoch: liveEpoch, CommitIndex: 5})
	mgr.SetCompactedThrough(sub, emission.EmitSeq{Epoch: liveEpoch, CommitIndex: 5})

	// Client reconnects claiming last-processed=2, which is BELOW the compaction
	// watermark (indices 3..5 are gone) -> design says STALE_SEQUENCE.
	prodReq := emission.ReconnectRequest{
		SubID:                sub,
		LastProcessedEmitSeq: emission.EmitSeq{Epoch: emission.EpochID{BucketUUID: "bkt", EpochCounter: 0}, CommitIndex: 2},
	}
	ack := mgr.Reconnect(prodReq)

	// CONVERT-ON-FIX: design-correct assertion is
	//   ack.Status == emission.ReconnectStaleSequence
	if ack.Status != emission.ReconnectOK || ack.NextCommitIndex != 0 {
		t.Fatalf("expected to reproduce bug (OK, next=0); got status=%v next=%d", ack.Status, ack.NextCommitIndex)
	}

	// Control: with the client's REAL (matching) epoch, the same inputs correctly
	// yield STALE_SEQUENCE — proving the hardcoded epoch 0 is the sole culprit.
	fixedReq := emission.ReconnectRequest{
		SubID:                sub,
		LastProcessedEmitSeq: emission.EmitSeq{Epoch: liveEpoch, CommitIndex: 2},
	}
	if ctrl := mgr.Reconnect(fixedReq); ctrl.Status != emission.ReconnectStaleSequence {
		t.Fatalf("control: expected STALE_SEQUENCE with matching epoch; got %v", ctrl.Status)
	}
	t.Logf("BUG REPRODUCED: epoch-0 request -> OK/next=0; matching epoch -> STALE_SEQUENCE")
}

// H2 — Cross-epoch outbox overwrite loss.
//
// outbox.go write() keys bySub by commit index only. After a restart the
// per-bucket commit index resets to low values while the epoch increases
// (RAFT_ARCHITECTURE.md §11.1), so a new-epoch entry at commit index N
// overwrites an undelivered old-epoch entry at commit index N.
func TestReachability_H2_CrossEpochOverwriteLoss(t *testing.T) {
	ctx := context.Background()
	mgr := emission.NewManager("bkt")
	e1 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 1}
	e2 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 2}
	sub := "c:1"

	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e1, CommitIndex: 1}, []byte("A"))
	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e2, CommitIndex: 1}, []byte("B"))

	pend := mgr.Pending(sub)
	// CONVERT-ON-FIX: design-correct assertion is len(pend) == 2 with both A and B present.
	if len(pend) != 1 || string(pend[0].Delta) != "B" {
		t.Fatalf("expected overwrite bug (only 'B' remains); got %d entries: %v", len(pend), pend)
	}
	t.Logf("BUG REPRODUCED: A (epoch1,ci1) overwritten by B (epoch2,ci1); A lost before delivery")
}

// H3 — Cross-epoch strand loss.
//
// pendingSorted orders by commit index (epoch-blind), but notifier.processTick
// skips by epoch. A new-epoch low-index entry is sent first, advancing
// sentThrough's epoch, after which every old-epoch entry is skipped forever.
func TestReachability_H3_CrossEpochStrandLoss(t *testing.T) {
	ctx := context.Background()
	mgr := emission.NewManager("bkt")
	e1 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 1}
	e2 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 2}
	sub := "c:1"

	// Old-epoch entry at a HIGHER commit index; new-epoch entry at a LOWER one.
	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e1, CommitIndex: 2}, []byte("OLD"))
	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e2, CommitIndex: 1}, []byte("NEW"))

	sender := &emission.MemorySender{}
	n := emission.NewNotifier(mgr, sender, nil, "bkt")
	n.TestTickOnce(ctx) // NEW (ci1) sent first -> sentThrough=(e2,1); OLD (e1,2) skipped (epoch<)
	n.TestTickOnce(ctx) // OLD still skipped

	events := sender.Snapshot()
	// CONVERT-ON-FIX: design-correct assertion is countDeltas(events, "OLD") >= 1.
	if countDeltas(events, "NEW") != 1 || countDeltas(events, "OLD") != 0 {
		t.Fatalf("expected strand bug (NEW delivered, OLD never); got NEW=%d OLD=%d",
			countDeltas(events, "NEW"), countDeltas(events, "OLD"))
	}
	t.Logf("BUG REPRODUCED: NEW (epoch2,ci1) sent first; OLD (epoch1,ci2) stranded forever")
}

// H4 — Same-epoch lost update across a fast reconnect.
//
// The notifier advances sentThrough at SEND time (before any client ACK). If the
// in-flight copy is lost on disconnect and the reconnect does not clear
// sentThrough, the entry (commit index <= sentThrough) is skipped forever. In
// production both clears are skipped: the disconnect-time clear loses the
// main.go:171-177 race, and the reconnect returns next=0 so SetResumeFrom early-
// returns without clearing (notifier.go:157-167).
func TestReachability_H4_SameEpochReconnectGap(t *testing.T) {
	ctx := context.Background()
	mgr := emission.NewManager("bkt")
	e := emission.EpochID{BucketUUID: "bkt", EpochCounter: 7}
	mgr.SetCurrentEpoch(e)
	sub := "client123:42"

	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e, CommitIndex: 1}, []byte("A"))

	sender := &emission.MemorySender{}
	n := emission.NewNotifier(mgr, sender, nil, "bkt")
	n.TestTickOnce(ctx) // sends A; sentThrough[sub]=(e,1). Client never ACKs (in-flight lost on disconnect).
	if countDeltas(sender.Snapshot(), "A") != 1 {
		t.Fatalf("setup: expected A sent once; got %d", countDeltas(sender.Snapshot(), "A"))
	}

	// Fast reconnect: race skips ClearWatermarksForClient; reconnect returns next=0,
	// so iothread calls SetResumeFrom(sub, 0) -> deletes resume, leaves sentThrough.
	n.SetResumeFrom(sub, 0)

	n.TestTickOnce(ctx) // A (ci1) <= sentThrough(1) -> skipped; never re-sent.
	n.TestTickOnce(ctx)

	// CONVERT-ON-FIX: design-correct assertion is countDeltas(...,"A") >= 2 (A re-sent
	// after reconnect because the client never processed it).
	if got := countDeltas(sender.Snapshot(), "A"); got != 1 {
		t.Fatalf("expected gap bug (A delivered exactly once, never re-sent); got %d", got)
	}
	t.Logf("BUG REPRODUCED: A sent once, lost in flight, never re-sent after reconnect (permanent gap)")
}

// P1 (emission-layer mechanism) — outbox resurrection re-delivers a purged delta.
//
// This reproduces the emission-layer non-idempotency that a restart triggers:
// on restart etcd/raft re-applies the committed log (Config.Applied is never set,
// types.go:998) and the applier re-proposes OUTBOX_WRITE for already-purged
// DATA_EVENTs (applier.go, no idempotency check) under a NEW wall-clock epoch
// (applier.go NewApplier). Here we drive the Manager/Notifier directly to show
// that once the same delta is re-written under a higher epoch, it is delivered a
// SECOND time despite having been delivered, acked, and purged — violating
// effective-once. (The raft re-apply itself is exercised by the integration test
// TestReachability_P1_OutboxResurrectionOnRestart.)
func TestReachability_P1_OutboxResurrectionMechanism(t *testing.T) {
	ctx := context.Background()
	mgr := emission.NewManager("bkt")
	e1 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 100}
	mgr.SetCurrentEpoch(e1)
	sub := "client123:42"

	sender := &emission.MemorySender{}
	n := emission.NewNotifier(mgr, sender, nil, "bkt")

	// First lifetime: write delta D at (e1,1), deliver, ack -> purge.
	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e1, CommitIndex: 1}, []byte("D"))
	n.TestTickOnce(ctx)
	n.Ack(&emission.ClientAck{SubID: sub, EmitSeq: emission.EmitSeq{Epoch: e1, CommitIndex: 1}})
	n.TestTickOnce(ctx) // drains ack -> ApplyOutboxPurge removes (e1,1)
	if got := countDeltas(sender.Snapshot(), "D"); got != 1 {
		t.Fatalf("setup: expected D delivered once; got %d", got)
	}
	if len(mgr.Pending(sub)) != 0 {
		t.Fatalf("setup: expected outbox purged after ack; pending=%v", mgr.Pending(sub))
	}

	// Restart: applier mints a new (greater) wall-clock epoch and re-applies the
	// committed DATA_EVENT for D, re-writing it under e2 at the same commit index.
	e2 := emission.EpochID{BucketUUID: "bkt", EpochCounter: 200}
	mgr.SetCurrentEpoch(e2)
	mgr.ApplyOutboxWrite(ctx, sub, emission.EmitSeq{Epoch: e2, CommitIndex: 1}, []byte("D"))
	n.TestTickOnce(ctx) // (e2,1) > sentThrough (e1,1) lexicographically -> NOT skipped -> delivered AGAIN

	// CONVERT-ON-FIX: design-correct assertion is countDeltas(...,"D") == 1 (effective-once).
	if got := countDeltas(sender.Snapshot(), "D"); got != 2 {
		t.Fatalf("expected resurrection bug (D delivered twice); got %d", got)
	}
	t.Logf("BUG REPRODUCED: purged delta D resurrected under new epoch and delivered twice")
}
