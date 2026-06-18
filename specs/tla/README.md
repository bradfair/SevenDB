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
| `EmissionContract.tla` | "effective-once delivery across crash / restart / migration" | **Counterexample found** (effective-once violated by outbox resurrection after restart) |

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
