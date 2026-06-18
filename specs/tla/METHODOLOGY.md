# Falsifying a system's correctness premises: a reusable playbook

A repeatable process for taking a system's *advertised guarantees* ("no lost
updates", "exactly-once", "linearizable", "deterministic"), turning them into
formal properties, finding where the implementation breaks them, and proving the
breaks are real — without fooling yourself.

It is built around one idea: **a bug you "found" is worthless until it has
survived a hostile attempt to refute it, and a model that "proves" a bug is
worthless until it has survived a hostile attempt to show it is rigged.** The
whole method is a sequence of adversarial gates.

This document is deliberately tool-light. We used TLA+/TLC, Go, and parallel
LLM sub-agents, but the structure transfers to any specification language, any
implementation language, and any reviewer (human or machine).

---

## When to use this

Use it when a system makes **global, cross-failure claims** that ordinary tests
cannot cover: properties about whole executions across crashes, restarts, leader
changes, reconnects, migrations, concurrency. Unit tests and even high-repetition
"run it 100 times" harnesses only sample *fixed schedules*; they cannot
enumerate the adversarial interleavings of fault + recovery that break global
invariants. That gap is exactly where this process pays off.

Do **not** reach for it for local, single-path logic — a normal test is cheaper.

---

## The loop

```
1. HARVEST    advertised guarantee  ->  falsifiable property (invariant)
2. MODEL      smallest faithful model of the real transition relation
3. CHECK      model-check; get a counterexample trace (or confidence)
4. ATTACK-BUG independent reviewer tries to REFUTE the bug in the code
5. ATTACK-MODEL independent reviewer tries to show the MODEL is rigged
6. REPRODUCE  executable test that reproduces the bug against real code
7. ASSESS     reachability + preconditions + honest confidence ordering
8. REPORT     what's real, what's conditional, what couldn't be shown
```

Phases 4 and 5 are the heart. Anyone can produce a counterexample to a model
they wrote; the value is created when the counterexample survives people trying
to destroy it.

---

## Core principles (the discipline that makes it trustworthy)

1. **The premise is the test.** Start from a sentence in the README / design doc
   / API contract, not from the data structures. Quote it. Turn it verbatim into
   a property. This keeps you testing the *system's own claims*, not your
   opinion of how it should behave.

2. **Model the transition relation the code actually implements, not an
   idealized one.** Every action in the model must correspond to a real code
   path; every modeling assumption must be a verifiable property of the code,
   with a citation. A model that "proves correctness" by quietly assuming away
   the bug is worse than no model.

3. **Faithfulness over elegance.** A model carries a *code-mapping* block: each
   action cites the function(s) it abstracts. If you can't cite it, you're
   guessing.

4. **Non-vacuity is mandatory.** An invariant that is simply always false proves
   nothing. Every "this is broken" result must be paired with a *discriminating
   variant* — a plausible fix, expressed in the same model — that makes the
   property hold. If the fixed variant doesn't pass, your invariant or model is
   wrong, not the system.

5. **Separate "the bug exists in code" from "my model is honest."** These are
   two different failure modes and need two different adversarial passes
   (phases 4 and 5). A faithful model of a real bug, a rigged model of a real
   bug, and a faithful model of a non-bug are three distinct situations; only the
   first is worth anything.

6. **Preconditions are findings, not footnotes.** "Real but only under X" is a
   different and often more useful result than "real." State X loudly.

7. **Report what you could NOT show.** The credibility of the positive results
   depends on visibly declining to claim the ones you couldn't substantiate.

---

## Phase 1 — Harvest premises into properties

- Read the README, design docs, and any "guarantees"/"semantics" sections.
  Extract each claim as a numbered premise with its source location.
- Classify each as **safety** ("nothing bad happens" — an invariant) or
  **liveness** ("something good eventually happens" — a temporal property).
- Write the formal statement next to the prose. Resist editorializing: if the
  doc says "exactly once in effect", model *effect count ≤ 1*, not your
  preferred definition.

Output: a table of `premise -> property -> source citation`.

> Worked example: "effective-once delivery — every change reflected to clients
> exactly once in effect, even across crashes/reconnects/migration" became the
> invariant `∀ delta: effects[delta] ≤ 1`.

---

## Phase 2 — Model the real transition relation

- **Layer the model.** Build a refinement stack so each property is checked at
  the altitude where it lives; abstract the layers below to their contract. Don't
  model the whole system at once.
- **Keep constants tiny.** These bugs are shallow — they show up at 1–3 objects,
  2 epochs, 2 nodes. Small bounds keep model-checking instant and traces
  readable.
- **Every action cites code.** Put the mapping in a header comment block.
- **Add the discriminating variant now**, not later: a boolean constant that
  switches between the real behavior and a plausible fix.

Faithfulness review of your own model before checking:
- Does the invariant flag any *benign/transient* state? (false-positive invariant)
- Is the fix variant defined *as* the spec? (tautology — proves nothing)
- Do `Init`/`Next` over-constrain so the bug is forced regardless of schedule?
- Does the model omit a real code path that would *prevent* the bug?

---

## Phase 3 — Model-check

- Get a **minimal counterexample trace**. Short traces map cleanly back to code.
- Verify the discriminating variant **passes**. If it doesn't, stop — the model
  is broken, not the system.

Model-checker gotchas worth knowing (TLC-specific, but the ideas generalize):
- **Benign terminal states** look like deadlocks. If your model legitimately
  ends (everything delivered), disable deadlock checking so the checker keeps
  hunting for the *real* invariant violation instead of halting on a dead end.
- **Closed-formula invariants give no witness.** If an invariant references only
  constants, the checker reports "false" with no example. Promote the inputs to
  *state variables* (enumerate them as initial states) so the tool hands you the
  exact failing assignment.
- **Discriminating variants must route through the modeled logic**, not be
  defined equal to the spec. (We shipped a tautological one and an adversarial
  reviewer caught it — see pitfalls.)

---

## Phase 4 — Adversarially attack the BUG (in the code)

Hand each finding to an **independent reviewer whose explicit job is to refute
it** by reading the actual code. Not to confirm — to break. Forbid trusting the
finding's framing.

The reviewer must check every link in the causal chain:
- Is each cited code fact actually true at that line?
- Is the precondition **reachable** in the real system, or only in theory?
- Is there a guard / dedup / clamp **elsewhere** that prevents it?
- Does an existing test already cover (or contradict) it?

Verdicts: **REFUTED** (with the code that prevents it) / **PARTIALLY AGREE**
(real but conditional — state the precondition) / **AGREE** (could not refute).

Run reviewers in **parallel, one per finding**, so they don't cross-contaminate.
A round where *everything* comes back AGREE is a yellow flag — check that the
reviewers were actually adversarial (did any come back qualified? did they find
evidence you didn't?).

> Worked example payoff: a "refute it" reviewer didn't just agree — it found and
> ran the repo's *own* existing e2e test, which already failed, upgrading the
> finding from "the model says so" to "the codebase's own test fails."

---

## Phase 5 — Adversarially attack the MODEL

A different attack surface from phase 4. Now the question is **"is the spec
honest, or did it bake in its conclusion?"** Give each reviewer the spec + the
code + the model-checker, and have them *mutate copies of the spec and re-run*.

Attack axes:
- **Vacuity:** is the invariant satisfiable at all in this model? Add a fix and
  confirm it passes.
- **False-positive invariant:** does it flag benign/transient states?
- **Forced path:** do `Init`/`Next` make the bug inevitable as an artifact?
- **Tautological fix:** is the "fix variant" secretly defined as the property?
- **Abstraction gaps:** what does the code do that the model omits — and would
  any of it prevent the bug?
- **Discrimination:** decouple multiple fix switches; show each defect fails
  *independently* and only fixing all of them passes (rules out a rigged toggle).

This phase routinely finds defects *in your specs* (it found two in ours). That
is the process working, not failing — fix the specs and re-run.

---

## Phase 6 — Reproduce executably against real code

A model proves inconsistency between premise and code-as-modeled. A test proves
the bug runs. Build the cheapest faithful reproduction.

- **Characterization tests.** Write the test to **pin the current (buggy)
  behavior** so the suite stays green, with a `CONVERT-ON-FIX:` comment giving
  the design-correct assertion to flip once fixed. This proves reachability
  without leaving red tests in a repo you may not own.
- **Add a control.** Where possible, assert the *correct* behavior under a
  neighboring condition (e.g. same inputs but the un-broken parameter) to prove
  the identified cause is the real culprit.
- **Tier by cost.** Reproduce at the cheapest level that's faithful:
  - *Unit* — pure module logic, microseconds. Most findings land here.
  - *Integration* — minimal real subsystem (e.g. a single-node consensus
    instance with persistence) when the trigger genuinely needs it.
- **Let reality correct the model.** Running the real thing often refines the
  picture: a bug the model says is unconditional may turn out timing-dependent,
  or two bugs may partially cancel. These are first-class findings.

> Worked example: building the integration test revealed the marquee bug was
> *timing-dependent* (gated by a leadership check at apply time) and could be
> *masked* by a second bug whose effects cancelled it — neither visible from the
> model alone. Both materially changed the severity assessment.

---

## Phase 7/8 — Assess reachability and report honestly

- Produce a **reachability map**: finding -> test -> level -> cost -> notes.
- State every **precondition** ("only on the restart-with-persistence path",
  "only intra-process", "only when the race is lost").
- Give a **confidence ordering** for anyone acting on the results: deterministic
  + runtime-confirmed + isolated first; racy / conditional / self-masking last.
- **List what you couldn't show** and why (e.g. a claim that's dedup-safe and has
  no confirmed divergent path). The omissions are part of the credibility.

---

## Reusable assets

### Adversarial prompt template — attack the BUG (phase 4)

```
You are an adversarial reviewer. REFUTE this bug claim by reading the ACTUAL
code at <path>. Do not trust the claim's framing — verify every link
independently and try hard to find a reason the bug is NOT real or NOT
reachable. Only AGREE if you genuinely cannot refute it.

CLAIM: <one sentence>
ALLEGED MECHANISM (verify each, cite file:line):
  1. <step>  2. <step>  ...
ATTACK THESE AXES:
  - Is the precondition reachable in the real system?
  - Is there a guard/dedup/clamp elsewhere that prevents it?
  - Does an existing test cover or contradict it?
  - Did the claim misread the code or the doc contract?
VERDICT: REFUTED (cite the preventing code) / PARTIALLY AGREE (state the
precondition) / AGREE (could not refute). Cite file:line for every assertion.
```

### Adversarial prompt template — attack the MODEL (phase 5)

```
You are an adversarial reviewer of a MODEL, not a bug. Determine whether <spec>
FAITHFULLY models the code or MISREPRESENTS it / bakes in its conclusion. You
have the model-checker; copy the spec and mutate it to test hypotheses.
ATTACK: vacuity; false-positive invariant; forced Init/Next; tautological fix
variant; abstraction gaps that would prevent the bug; genuine discrimination
(does the fix pass for a real reason?). Run experiments.
VERDICT: FAITHFUL / OVERSTATED / RIGGED / FALSE-POSITIVE-INVARIANT, with the
experiments you ran and file:line + spec-line citations.
```

### Tips for running LLM sub-agents as reviewers
- One agent per finding, **in parallel**; isolate their context so they don't
  anchor on each other or on you.
- Tell them the conclusion is *not* authoritative and their job is to break it.
- Give them the tools to *run* things (the checker, the test runner). A reviewer
  that can execute beats one that can only read.
- Treat unanimous agreement skeptically; treat a *qualified* dissent as a sign
  the panel is genuinely critical.

### Characterization-test pattern
```
// Reproduces <finding>. Pins CURRENT (buggy) behavior so the suite stays green.
// DESIGN CONTRACT: <what should hold, with doc citation>.
// CONVERT-ON-FIX: change the assertion below to <design-correct assertion>.
<exercise the real code path>
<assert the observed buggy outcome>     // + a control asserting the cause
```

---

## Pitfalls we hit (and how the process caught them)

These are real; they are why the adversarial gates exist.

1. **Tautological fix variant.** A spec's "fix" was defined as literally equal to
   the spec, so its sanity check passed by reflexivity and proved nothing. Caught
   in phase 5; reworked so the fix routes through the modeled logic.
2. **Model said "always", reality said "sometimes".** The headline bug was
   unconditional in the model but *timing-dependent* in the integration test
   (gated by a state check at apply time). Caught in phase 6; reported as racy.
3. **Two bugs cancelling.** A second defect's effect masked the first under a
   common condition, so the naive end-to-end repro showed nothing. Caught by
   instrumenting what the real subsystem actually did, not assuming.
4. **A reviewer's own strawman.** An adversarial reviewer attacked a model with a
   wrong assumption about the code, discovered the real behavior mid-review, and
   *retracted its own attack*. The point: even the adversary must verify against
   code, and self-correction is a feature.
5. **Checker halting on benign dead-ends / giving no witness.** Tooling defaults
   hid the real result until configured correctly (disable deadlock checking;
   promote inputs to state variables for witnesses).

---

## TL;DR checklist

- [ ] Premise quoted from the system's own docs, turned into a property.
- [ ] Model cites code for every action; constants tiny.
- [ ] Counterexample trace is minimal and maps to code.
- [ ] Discriminating fix variant **passes** (non-vacuity).
- [ ] Independent reviewer **failed to refute the bug** (phase 4).
- [ ] Independent reviewer **failed to show the model is rigged** (phase 5).
- [ ] Executable test reproduces it; characterization-style; has a control.
- [ ] Reachability + preconditions stated; confidence ordering given.
- [ ] What you could **not** show is written down.

If only one habit survives from this: **never trust your own counterexample
until something has tried, and failed, to take it away from you.**
