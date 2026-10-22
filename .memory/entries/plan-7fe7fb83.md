---
id: plan-7fe7fb83
type: plan
project: menegroth
parent_id: plan-b2670c25
title: 'Overnight authorization (2026-10-21 night): finish gravity audit, then pre-ribbed
  fixes, then citation sweep'
node_label: 'Overnight run 2: audit close-out + 2 runs'
tags: overnight,autonomous,coordinator,gravity-audit,operating-rules
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm.jl@cdcd627,
  .cursor/agents.yaml@290b8b4
session_id: sess-6ce4ffdf
created_at: '2026-10-22T02:14:46.934334+00:00'
updated_at: '2026-10-22T02:14:46.934334+00:00'
---
User authorized a second autonomous overnight run on 2026-10-21 ~22:13 ET. Drive the coordinator wave loop without stopping for per-cycle approval; the only thing to escalate is the wholesale-FEA decision (below).

SEQUENCE (in order):
1. Finish cycle 13b on run-45efe717 (eng15 task-94a66636 running → rev15 task-c748e11e → crit15 task-a5dd9d23). Fix = generalize the Eq. (13-7) under-centerline guard: any transverse strip not bounded by panel centerlines on BOTH sides is invalid DDM geometry (§13.6.2.1) → throw → NaN + :failure → FEA fallback. crit15 is the generality test.
2. CLOSE-OUT this audit (new tasks after crit15 passes): code-steward pass over the cumulative gravity diff (report-only unless P1; persona now in .cursor/agents.yaml, checker, inherits coordinator model); full StructuralSizer + StructuralSynthesizer suites + scripts/runners/audit_trace_coverage.jl (note pre-existing broken tier-1 test and malformed @test in StructuralSynthesizer/test/core/test_uniform_column_sizing.jl:96 — do not 'fix' them); memory checkpoint under plan-b2670c25 with the ENGINEERING-JUDGMENT list for morning review.
3. PRE-RIBBED fixes run (new graph): footing tension dowel φ=0.90 (§9.3.2.1); signed column hogging envelope + fallback; AISC 360-16 §H1 single-combination P-M + forward Pu,t + §H1.2 tension+hogging; 0.75L partial live pattern (§13.7.6.3) + adjacent-frame patterns (§8.11.2); edge-column biaxial punching (PCA EB712 Fig 16-13); sloped-rafter signed moment; general CompositeContext w/ irregular tributary + overrides; per-column span/width override hook; consolidate duplicates (B1 block, ROT secondary-moment, _support_positions vs _support_span_xy, _pattern_demand_cases). Cosmetic: explain_feasibility wrong governing check + sentinel 'I3.2b' label; tie viz Dx==Dy.
4. CITATION SWEEP run (new graph, before ribbed floors): every gravity code path vs corpus; resolve the ACI 318-11 §13.6 vs 318-19 §8.10 edition mix (targets in the 2026-10-21 citation-sweep note); FEA strip/punching on irregular plans; R=10 honeycomb iteration-cap finding.
Then ribbed floors (NOT this run).

OPERATING RULES (binding):
- NO git commits during the autonomous run (anno preference). A memory record precedes any future commit.
- Code-correct ('proper') option over a blanket-conservative shortcut (anno-45fbbf11). When mechanics are GENUINELY ambiguous, take the conservative option, label ENGINEERING JUDGMENT, and add to the morning-review list rather than block.
- Walls and lateral OUT of scope (another chat's run-5cd4e3a2 holds lateral_evaluator.jl). Never take a whole-workspace write lease; scope every engineer's writes.
- Never run two Gurobi-loading Julia processes at once (codesign race → hang). pgrep-guard before any Julia; reviewers verify by reading when a checker is running Julia.
- Checker model pins: reviewer claude-opus-4-8-thinking-high IS launchable; critic claude-opus-5-5-thinking-high is NOT → runs on inherit. Engineer grok pin not launchable → inherit.
- Extension cap 5 (run-45efe717 at 3 after 13b). Keep spending extensions ONLY while the critic finds REAL unconservative moments; at the cap, escalate rather than force.
- ESCALATE TO USER (do not auto-decide): if crit15 (or any later critic) finds another DISTINCT unconservative Eq. (13-7) path, do NOT keep point-patching — propose gating the whole irregular-coverage path to FEA wholesale.

RESUME NOTE: if the coordinator MCP restarts and run-45efe717 is orphaned, manage_runs(action='resume', run_id='run-45efe717') and continue the wave loop. State file .angelo/coordinator-state.json.
