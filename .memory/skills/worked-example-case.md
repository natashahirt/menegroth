---
id: worked-example-case
name: worked-example-case
category: pattern
tags: testing,worked-example,case,numerical,tolerance,zettelkasten
status: active
created_at: '2026-07-12T23:09:25.944671+00:00'
updated_at: '2026-07-12T23:09:25.944671+00:00'
---
# Skill (pattern): worked-example-case

The **case note** is the machine-readable record of one worked example from the
corpus (`role: examples`). It is the single artifact that serves as the
numerical-test oracle, the regression fixture, the report baseline, and the
target of a synapse `verifies` edge. Extract once; generate the rest.

**Identity.** The note id IS the corpus id of the example (see
`citation-join-key`), e.g. `sp-de-combined-footing-aci318-14`.

**Fields.**
- `id`: corpus id of the example.
- `system`: the design system it validates (e.g. "combined footing, ACI 318").
- `source`: document title, edition, example number, page(s).
- `governing_clauses`: list of `corpus_id#clause` the example exercises.
- `given`: inputs with units (geometry, loads, material props).
- `expected`: reference outputs with units (the numbers to reproduce).
- `tolerance`: per-output `rtol`/`atol` AND the reason (why the band is what it
  is - e.g. "impl is more conservative than the reference by design").
- `notes`: known discrepancies, assumptions, gotchas.

**Test generation.** Each `expected` entry becomes a `@test isapprox(computed,
expected; rtol=...)` (or a bounded range when the implementation is deliberately
more conservative). The test header cites `source` + `(corpus: <id>)` so the
oracle is traceable. Follow `.cursor/rules/testing.mdc`.

**Rule.** If the implementation cannot reproduce `expected` within `tolerance`,
STOP and report the discrepancy. Do not widen `tolerance` to force a pass -
that erases the signal the case note exists to provide.
