---
id: chec-a0a6a723
type: checkpoint
project: menegroth
parent_id: deci-473a0335
title: 'row-f-nlp merge: committed, builds, three merge-interaction bugs fixed; sign-off
  list open'
node_label: merge checkpoint
tags: merge,row-f-nlp,cladding,pattern-loading,service-deflection,signoff
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-baa001eb
created_at: '2026-11-19T05:28:53.753300+00:00'
updated_at: '2026-11-19T05:28:53.753300+00:00'
---
Merge commit 9fcdafad on `merge/row-f-nlp` (worktree `.merge-worktree/`). Both packages precompile after removing an auto-merge duplicate `RCColumnDemandSet`.

Fixes after the full suites ran (merge interactions, not present on either side alone):
- pattern_cases.jl: row-f-nlp added `:cladding` to `case_full/case_a/case_b`, which the refactored function no longer has (`case_a` UndefVarError). Cladding now rides in `extras` (dead on every case).
- demands.jl `_service_dead_live_loads`: `:cladding` LineLoad threw (no D/L split). Factored copy skipped; `unfactored_cladding_loads` added to `dead`. NOT added to `sdl` (L/240 superimposed-dead+live set) -> sign-off.
- foundation_reactions.jl (row-f-nlp file): called 4-arg `_wind_loads` and 2-arg `seismic_effect_loads`; updated to the refactor's `(struc, ..., centroids)` / `(struc, elf, e)` forms.
- api/diagnose/context.jl: description for the new default `punching_strategy = :joint_search`.
- test_row_f_resize.jl fixture: story 0 is now the support level with no beams; fixture copies the story-1 beam plan and faces to grade (as test_ordinary_wall_stage does).

Full-suite results before these fixes: Sizer 12993 pass / 5 fail / 3 err; Synth 8728 / 12 / 88. Remaining clusters (sloped-edge fixtures, story-0 fixtures, `:lineload` test loads, override-refusal wording, circular NLP returning nothing) are being compared against a baseline run of the unmerged snapshot in `.baseline-worktree/`.

Gotcha: running two `test_quiet --fresh` suites at once races Gurobi_jll's `codesign --remove-signature` on the shared artifact and fails both; run suites sequentially.

OPEN SIGN-OFF: Row F floor relaxation vs overstress floors; RC column demand sets = case rows x axis swap (2->4 cases); joist rib depth (h - hf) vs h for ACI 318-19 §9.8.1.3 'overall depth of ribs' (p.153, ambiguous); dropped T-beam εt≥0.004 early return; footing combos reused in development loop; Ec 33w^1.5√f'c vs 57000√f'c in NLP deflection; unknown-αfm two-way bound ln/29.75 (engineering judgment); default punching_strategy :joint_search + column reseed on thickness change (untested together); scene labels 318-19 §24.2 vs 318-11 deflection check; cladding in sdl for L/240.
