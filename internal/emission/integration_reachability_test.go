package emission_test

// Integration reachability tests that drive a REAL single-node etcd raft node
// (with persistence) through the emission Applier, to confirm which bugs are
// reachable end-to-end (not just at the Manager/Notifier layer). These are
// slower (they advance a simulated clock to elect a leader) and are tagged in
// their names with the finding they exercise. Like the unit-level reachability
// tests, they PIN CURRENT BEHAVIOR and document the design-correct assertion.

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/sevenDatabase/SevenDB/config"
	"github.com/sevenDatabase/SevenDB/internal/emission"
	"github.com/sevenDatabase/SevenDB/internal/harness/clock"
	raftimpl "github.com/sevenDatabase/SevenDB/internal/raft"
)

func electLeader(t *testing.T, node *raftimpl.ShardRaftNode, clk *clock.SimulatedClock) {
	t.Helper()
	for i := 0; i < 4000; i++ {
		if node.IsLeader() {
			return
		}
		clk.Advance(10 * time.Millisecond)
		time.Sleep(300 * time.Microsecond)
	}
	t.Fatalf("no leader elected")
}

// P1 (end-to-end) — a real restart re-applies the committed DATA_EVENT and the
// leader re-proposes a fresh OUTBOX_WRITE under a NEW wall-clock epoch, so an
// already-committed delta is re-emitted (resurrected). This confirms the raft
// re-apply path (Config.Applied never set, types.go:998) actually triggers the
// emission-layer resurrection proven by the unit test.
func TestReachabilityIntegration_P1_RestartResurrection(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping raft restart integration test in -short mode")
	}
	dir := t.TempDir()
	sub := "c:1"

	// ---- Lifetime 1: commit one DATA_EVENT, leave it un-acked. ----
	clk1 := clock.NewSimulatedClock(time.Unix(0, 0))
	n1, err := raftimpl.NewShardRaftNode(raftimpl.RaftConfig{ShardID: "sh", NodeID: "1", Peers: []string{"1@self"}, DataDir: dir, Engine: "etcd", TestDeterministicClock: clk1})
	if err != nil {
		t.Fatalf("n1: %v", err)
	}
	electLeader(t, n1, clk1)
	mgr1 := emission.NewManager("sh")
	ctx1, cancel1 := context.WithCancel(context.Background())
	emission.NewApplier(n1, mgr1, "sh").Start(ctx1)
	rec, _ := raftimpl.BuildReplicationRecord("sh", "DATA_EVENT", []string{sub, "D"})
	if _, _, err := n1.ProposeAndWait(ctx1, rec); err != nil {
		t.Fatalf("propose: %v", err)
	}
	for i := 0; i < 3000 && len(mgr1.Pending(sub)) == 0; i++ {
		clk1.Advance(10 * time.Millisecond)
		time.Sleep(300 * time.Microsecond)
	}
	if len(mgr1.Pending(sub)) == 0 {
		t.Fatalf("L1: outbox entry never appeared")
	}
	epoch1 := mgr1.Pending(sub)[0].Seq.Epoch.EpochCounter
	cancel1()
	_ = n1.Close()
	time.Sleep(40 * time.Millisecond)

	// ---- Lifetime 2: restart from the same DataDir with a fresh Manager. ----
	time.Sleep(2 * time.Millisecond) // ensure the wall-clock epoch advances
	clk2 := clock.NewSimulatedClock(time.Unix(100, 0))
	n2, err := raftimpl.NewShardRaftNode(raftimpl.RaftConfig{ShardID: "sh", NodeID: "1", Peers: []string{"1@self"}, DataDir: dir, Engine: "etcd", TestDeterministicClock: clk2})
	if err != nil {
		t.Fatalf("n2: %v", err)
	}
	defer n2.Close()
	mgr2 := emission.NewManager("sh")
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	// Deterministically force the triggering interleaving: become leader first, so
	// the buffered re-delivered DATA_EVENT is consumed while IsLeader()==true and the
	// resurrected OUTBOX_WRITE proposal succeeds. (In the continuous-applier ordering
	// this is racy: if the replay is consumed before election, ProposeAndWait fails
	// with NotLeaderError and no resurrection occurs -- P1 end-to-end is timing-dependent.)
	electLeader(t, n2, clk2)
	emission.NewApplier(n2, mgr2, "sh").Start(ctx2)

	resurrected := false
	for i := 0; i < 3000; i++ {
		p := mgr2.Pending(sub)
		if len(p) > 0 && p[0].Seq.Epoch.EpochCounter > epoch1 {
			resurrected = true
			t.Logf("BUG REPRODUCED (end-to-end): delta re-emitted under new epoch %d > %d after restart", p[0].Seq.Epoch.EpochCounter, epoch1)
			break
		}
		clk2.Advance(10 * time.Millisecond)
		time.Sleep(300 * time.Microsecond)
	}
	// CONVERT-ON-FIX: design-correct assertion is !resurrected (the committed delta
	// is NOT re-emitted under a new epoch after restart).
	if !resurrected {
		t.Fatalf("expected resurrection (outbox entry under epoch > %d) after restart", epoch1)
	}
}

// H5 (end-to-end) — raft snapshot+compaction is triggered purely by committed
// volume and runs even though the outbox is full of UN-ACKED emissions, with no
// reference to client acks (types.go:1461-1479). This confirms compaction is
// decoupled from the emission ack watermark (the §8 safety_point is unimplemented).
func TestReachabilityIntegration_H5_CompactionIgnoresUnackedOutbox(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping raft snapshot integration test in -short mode")
	}
	// Enable snapshots at a low threshold. Save/restore the global config.
	prev := config.Config
	config.Config = &config.DiceDBConfig{}
	config.Config.RaftSnapshotThresholdEntries = 4
	defer func() { config.Config = prev }()

	dir := t.TempDir()
	clk := clock.NewSimulatedClock(time.Unix(0, 0))
	node, err := raftimpl.NewShardRaftNode(raftimpl.RaftConfig{ShardID: "sh", NodeID: "1", Peers: []string{"1@self"}, DataDir: dir, Engine: "etcd", TestDeterministicClock: clk})
	if err != nil {
		t.Fatalf("node: %v", err)
	}
	defer node.Close()
	electLeader(t, node, clk)
	mgr := emission.NewManager("sh")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	emission.NewApplier(node, mgr, "sh").Start(ctx)

	// Commit several DATA_EVENTs (each becomes an un-acked OUTBOX_WRITE). None are acked.
	for i := 0; i < 6; i++ {
		rec, _ := raftimpl.BuildReplicationRecord("sh", "DATA_EVENT", []string{fmt.Sprintf("c:%d", i), "D"})
		if _, _, err := node.ProposeAndWait(ctx, rec); err != nil {
			t.Fatalf("propose %d: %v", i, err)
		}
	}

	// Wait for a snapshot to occur while un-acked outbox entries are still pending.
	snapped := false
	for i := 0; i < 4000; i++ {
		st := node.Status()
		if st.LastSnapshotIndex > 0 {
			snapped = true
			pending := 0
			for _, c := range []string{"c:0", "c:1", "c:2", "c:3", "c:4", "c:5"} {
				pending += len(mgr.Pending(c))
			}
			t.Logf("BUG REPRODUCED: snapshot at index %d (pruned through %d) while %d un-acked outbox entries pending — compaction ignored client acks",
				st.LastSnapshotIndex, st.PrunedThroughIndex, pending)
			// CONVERT-ON-FIX: design-correct assertion is that compaction never advances
			// past the un-acked watermark, i.e. snapshot must NOT occur with pending>0.
			if pending == 0 {
				t.Fatalf("expected un-acked outbox entries to still be pending at snapshot time")
			}
			break
		}
		clk.Advance(10 * time.Millisecond)
		time.Sleep(300 * time.Microsecond)
	}
	if !snapped {
		t.Fatalf("expected a volume-triggered snapshot to occur")
	}
}
