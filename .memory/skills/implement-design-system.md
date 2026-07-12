---
id: implement-design-system
name: implement-design-system
category: procedural
tags: dev-loop,workflow,coordinator,design,structural,autonomous
status: active
created_at: '2026-07-12T23:09:25.941058+00:00'
updated_at: '2026-07-12T23:09:25.941058+00:00'
---
# Skill: implement-design-system

**When to use.** Any autonomous run whose goal is to implement (or extend) a
structural design system in menegroth - a new design code, member/section type,
slab system, foundation type, or a StructuralSynthesizer system. This is the
canonical dev loop; follow it end-to-end so every system lands with the same
rigor and the same knowledge-graph footprint.

**Companion skills:** `citation-join-key` (how code/tests/notes link to canon),
`worked-example-case` (the numerical test-oracle schema). Read both first.

**Repo discipline this builds on:** `.cursor/rules/corpus.mdc` (citation
contract), `.cursor/rules/code-accuracy.mdc` (clause numbers in comments),
`.cursor/rules/testing.mdc` (known-answer tests with tolerances).

---

## The loop (stage -> gate)

0. **locate** (read-only). `search`/`recall` the architecture tree
   (`plan-a0000001`) + `codebase()` to find where the system belongs
   (StructuralSizer code family vs. member/section vs. StructuralSynthesizer
   system), the checker/optimizer split to mirror, and the nearest neighbor to
   copy conventions from. Record a `plan` node for the system.
   - Gate: proceed. STOP only if placement is architecturally novel.

1. **gather canon** (read-only). Query the zettelkasten by family/spine for the
   governing clauses; pull verbatim clause text + page and the `role: examples`
   worked examples. Resolve `corpus_id#clause` anchors. Emit a canon-manifest
   `note` listing every clause and worked-example case id to build against.
   - HARD STOP if canon is missing, ambiguous, editions conflict, or there is no
     worked example to validate against.

2. **implement** (writes code). Write Julia at the located insertion point under
   the citation contract: every formula/clause commented
   `(corpus: <id>, Sclause, p.N)`, `CheckResult(..., "<clause>")` provision
   strings, `ENGINEERING JUDGMENT` tags for non-code choices. Mirror the
   neighbor. Record `decision` entries (why/what/how). Generate the engineering
   report artifact. Add synapse `implements` edges (code <-> clause note) via the
   shared corpus_id (see `citation-join-key`).
   - Gate: proceed.

3. **test** (writes tests). For each worked-example case note, generate a
   numerical test (given inputs -> expected within stated tolerance) in the repo
   style (header cites `corpus:` id + example; `isapprox(...; rtol=...)`). Add
   regression tests. Run the suite. Add synapse `verifies` edges
   (test <-> example <-> code).
   - HARD STOP if a worked example cannot be reproduced within a defensible
     tolerance. NEVER loosen a tolerance to force green - report the discrepancy.

3b. **review** (read-only). Blind verification that every clause is cited
    correctly and the logic matches the canon before anything ships.

4. **record** (meta). Register the report as a memory `document`; write a
   `checkpoint` (implemented, pending review) with the jump-links.

5. **assemble PR** (orchestrator, not a coordinator agent). Branch `feat/<system>`,
   commit code + tests + report, push, open a PR whose body links the plan node,
   the canon manifest, a worked-example results list, and the synapse edges.
   - HARD STOP: human review before merge.

---

## Autonomy guardrails
- **Decide alone:** naming, file placement among equivalents, which neighbor to
  mirror, test structure, formatting, tolerance WITHIN a documented band.
- **Must STOP:** missing/ambiguous/conflicting canon; worked example not
  reproducible; architecturally novel placement; any `ENGINEERING JUDGMENT` not
  backed by a clause; loosening a tolerance; merge.

---

## Coordinator task graph (validated against validate_graph)

Stages 0-4 are delegatable to the coordinator; stage 5 (git/PR) is the
orchestrator's closing action. Instantiate a fresh graph per run:

```python
from coordinator.graph import validate_graph  # optional pre-check
tasks = [
  {"alias": "locate",    "agent": "explore",  "depends_on": [],
   "writes": [],
   "description": "Read-only: locate the system in the architecture tree (plan-a0000001) and codebase() graph. Identify package, checker/optimizer split, nearest neighbor. Record a plan node."},
  {"alias": "canon",     "agent": "explore",  "depends_on": ["locate"],
   "writes": [],
   "description": "Read-only: query the zettelkasten for governing clauses + role:examples worked examples; resolve corpus_id#clause anchors; emit the canon-manifest note. HARD STOP if canon missing/ambiguous or no worked example."},
  {"alias": "implement", "agent": "engineer", "depends_on": ["canon"],
   "writes": ["<TARGET_PKG>/src"],
   "description": "Implement the logic under the citation contract (.cursor/rules/corpus.mdc). Comment each clause (corpus: id, clause, page); CheckResult provision strings; ENGINEERING JUDGMENT tags. Record decision entries. Generate the engineering report. Add synapse implements edges."},
  {"alias": "test",      "agent": "tester",   "depends_on": ["implement"],
   "writes": ["<TARGET_PKG>/test"],
   "description": "Generate numerical tests from each worked-example case note (isapprox with the stated tolerance) + regression tests; run the suite. Add synapse verifies edges. HARD STOP if a worked example is not reproducible; never loosen tolerance to force green."},
  {"alias": "review",    "agent": "reviewer", "depends_on": ["implement"],
   "writes": [],
   "description": "Blind review: verify every clause citation and that the logic matches the canon; flag any uncited magic numbers."},
  {"alias": "record",    "agent": "memory",   "depends_on": ["test", "review"],
   "writes": [],
   "description": "Register the report as a memory document; write a checkpoint (implemented, pending review) carrying the jump-links (corpus_ids + decision ids)."},
]
# validate_graph(tasks, agent_roles=AGENT_ROLES) -> [] (valid: planner roots,
# one implementer, checkers descend from it, meta exempt)
graph.create_graph(tasks=tasks, goal="Implement <SYSTEM> per <CODE>")
```

Set `<TARGET_PKG>` from stage 0 (e.g. `StructuralSizer`). Run with
`get_ready_tasks`/`claim_task`; resume an interrupted run with `restore_tasks`.
Graph state lives in `.angelo/` (transient); reasoning lives in `.memory/`.

---

## Definition of done (per run)
Located + plan node; canon gathered with verbatim citations; logic implemented
with the full citation contract; every governing clause exercised by a test;
every available worked example reproduced within tolerance; regression tests
added; engineering report emits the jump-links; branch + PR opened; memory +
synapse updated; ZERO un-cited magic numbers.

## Per-run memory footprint
one `plan` node (the system) + `decision` entries + a canon-manifest `note` +
a report `document` + a `checkpoint`, with `implements`/`verifies` synapse edges.
