# SevenDB — TLA+ specifications

Formal models of SevenDB's correctness premises, written so that TLC checks
the **implementation's actual behavior** against the guarantees the design
documents claim.

See [`STRATEGY.md`](./STRATEGY.md) for the full top-down testing strategy,
the premise→invariant decomposition, the layered spec plan, and the catalog
of bug hypotheses with code citations.

## Specs

| Module | Premise under test | Status |
|--------|--------------------|--------|
| `EmissionContract.tla` | P1 "effective-once delivery across crash / restart / migration" | **Counterexample found** — effective-once violated by outbox resurrection after restart |
| `Reconnect.tla` | P5 reconnect resumes from `commit_index+1` / STALE / INVALID | **Counterexample found** — production reconnect always returns `OK, next=0` (epoch hardcoded to 0); fix variant (`FixHolds`) passes |
| `Migration.tla` | P3/P6 gap-free order; previous epoch drained before new emissions | **Counterexample found** — cross-epoch outbox keyed by commit index loses an entry (overwrite + epoch-regression strand); `EpochAwareOutbox=TRUE` fix passes |
| `Compaction.tla` | P8 never compact beyond `min` client ack | **Counterexample found** — volume-triggered snapshot (nil data) prunes un-acked emissions; `AckAwareCompaction=TRUE` fix passes |
| `Rebind.tla` | P3/P4 no same-epoch lost update across reconnect | **Counterexample found** — fast-reconnect race + `next=0` leave `sentThrough` uncleared, stranding an unprocessed entry; `CorrectReconnect=TRUE` fix passes |

## Running TLC

Download the tools once:

```sh
curl -fsSL -o tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar
```

Check a spec. Use `-deadlock` because terminal states (everything delivered
and purged) are expected and benign here — we are checking safety invariants,
not deadlock-freedom:

```sh
java -cp tla2tools.jar tlc2.TLC -deadlock \
  -config EmissionContract.cfg EmissionContract.tla
```

Expected output for `EmissionContract`: `Error: Invariant EffectiveOnce is
violated.` followed by a 7-state trace showing the same source delta delivered
to the client twice — once under epoch 1, then again (resurrected from the
durable outbox) under epoch 2 after a restart.

```sh
java -cp tla2tools.jar tlc2.TLC -deadlock \
  -config Reconnect.cfg Reconnect.tla
```

Expected output for `Reconnect`: `Error: Invariant ReconnectSound is violated`
with witness `pos=0, ack=0, comp=0` (design wants `OK, next=1`; production
returns `OK, next=0`). The same module's `FixHolds` invariant — which threads
the client's real epoch instead of the hardcoded `0` — passes over all inputs,
proving the property is not vacuous.

`Migration.tla` and `Compaction.tla` each carry a CONSTANT that switches
between the real behavior (invariant fails) and a candidate fix (invariant
passes); see the `.cfg` headers. Set `EpochAwareOutbox` / `AckAwareCompaction`
to `TRUE` to watch the fix variant pass.
