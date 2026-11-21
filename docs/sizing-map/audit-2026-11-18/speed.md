# Speed audit, 2026-11-18

Where `design_building` runtime goes, what forces it, and ranked ways to cut
it. Read-only audit of the working tree on 2026-11-18. No code was run; every
number below comes from an existing log, profile or memory entry, cited by
path. Tags: **[read]** = verified in code or a log; **[inferred]** = reasoning
from those, not measured.

Paths: `SS/` = `StructuralSizer/src/`, `SY/` = `StructuralSynthesizer/src/`,
`Asap/` = `external/Asap/src/`, `FEA/` = `SS/slabs/codes/concrete/flat_plate/analysis/fea/`.

---

## 1. Measured costs

### 1a. Whole-building runs

`design_building timing` is the `@info` block printed by `design_building`
(prepare / pipeline / capture / total, seconds). ANSI codes stripped.

| Building | Configuration | Total | Breakdown | Source |
|---|---|---|---|---|
| Core office v5, 4 st, 3×3 at 8 m, core walls | Flat plate FEA `:strip`, rigid diaphragm, gravity walls, `:all_spread`; Gurobi; 8 threads | **951 s** "design" (825.6 s inside the timer) | prepare 106.9, **pipeline 699.2**, capture 19.3; then analysis model 65.1, build_scene 42.4, design file 16.9 (outside `design_building`) | `logs/core_office_v5_design.log` [read] |
| Core office v6 | same | 783.5 s design (668.9 timed) | prepare 95.6, pipeline 559.6, capture 13.5 | `logs/core_office_v6_design.log` [read] |
| Core office v2 (64 frame elements) | same, earlier code | 1775.7 s design (1638.2 timed) | prepare 132.6, **pipeline 1446.9**, capture 58.4; analysis model 199.9 | `logs/design_core_office_v2.log` [read] |
| Core office (NaN-guard run) | same | 1173.3 s timed | prepare 166.4, pipeline 974.3 | `logs/design_core_office_nan_guard.log` [read] |
| Core office (Nov 4 memory) | same | 1481 s | — | `.memory/entries/expe-fbdb2363.md` [read] |
| 4-story flat plate (the "66 min" run) | Flat plate FEA, corner columns walked to the 30 in cap | ~3960 s | No log in `logs/`. Parent session: corner columns stuck at 30×30, every column change remeshes the slab | parent chat [d96f45bc](d96f45bc-c1db-4d74-8fc7-f5c10b49940e) [read, no stage split] |
| 1-story 3×3-bay plate, 60×48 ft, 125 psf LL, `:individual` | FEA, `max_iterations=5`, corner columns to cap then slab 10→10.5 in | **1686 s** | — | `.memory/entries/chec-0482ba24.md` [read] |
| Medium office 159×108 ft, 8×5 bays, 3 st | Flat plate FEA, warm | **567 s, ~91 % in Asap** | Asap split: `_update_S_values!` 38 % (since fixed 10–13×), shell meshing 34 %, populate_loads 8 %, solve 6 % | `.memory/entries/chec-c963ee3a.md` (profile runner `scripts/runners/profile_design_building_asap.jl`) [read] |
| same | DDM / default / steel, warm | **~3.75 s**, Asap < 1 % | MIP column sizing ~63 %, DDM eq. 13.7 transfer ~18 %. Cold first call 145 s compile + 12 s load | same entry [read] |
| SDC sensitivity, 5-story beam + wall buildings | Story shell, ELF, walls, RC beams/columns | **434–988 s** per case (8 cases) | — | `logs/sdc_design_sensitivity.txt`, `sdc_design_sensitivity_one.txt` [read] |
| Sweep smoke, 20 ft bays | DDM n3 / n6 stories | 100.7 / 103.8 s | worker start-up **759.8 s** (precompile 605 s) | `logs/sweep_smoke_rerun.log` [read] |
| same | FEA n3 / n6 stories | **416.6 / 597.0 s** | — | same [read] |
| StructuralStudies speed baseline, 28 ft bays | DDM (Full) vs FEA (frame) | 85.0 s vs 262.4 s (earlier 98.6 vs 294.7; one noisy run 544.8) | — | `.memory/entries/note-e5f9956e.md`, `chec-fb39015c.md` [read] |
| Test-suite flat-plate designs (first call in process) | various | 223–853 s | prepare **50–140 s** on the first call, **0.01–0.1 s** on later calls in the same process | e.g. `logs/test_StructuralSynthesizer_20261108_185555.log` (139.6 / 705.6 / 8.2), `…20261117_104418.log` (59.8 / 313.2 / 27.0) [read] |
| SDF trials, small grids | rib / joist floors | 18–85 s | first call 85 s, later 18–20 s | `logs/sdf_trials_1.log` [read] |
| grid/x1y1 steel two-way | story shell, steel joists | 510 s | — | `logs/sdf_rib_design/grid_x1y1_joist_systems/steel_twoway.txt` [read] |

Reading of the table:

- `prepare` is mostly compilation. It falls from 50–140 s on the first call to
  under 0.1 s on the next call in the same process [read, logs above]. The
  difference between "design" and the timed total (126 s on core office v5)
  is also first-call latency [inferred].
- Flat-plate FEA runs are 5–100× slower than the same building with DDM, and
  almost all of the difference is in the slab analysis [read, chec-c963ee3a].
- No log splits the core-office `pipeline` (699 s) by stage. It is the
  largest unexplained number (open question 1).

### 1b. Flat-plate FEA: per-analysis cost and remesh A/B

Single medium-office slab mesh, 8 threads (`scripts/runners/bench_asap_fea_slab.jl`):

| Quantity | v1 (Oct 26) | v2 (Oct 26, after fixes) | Source |
|---|---|---|---|
| Mesh | 31,248 nodes, 61,767 ShellTri3, 108 frame, **185,870 free DOFs, nnz(S) = 7.8 M** | same | `logs/bench_asap_fea_slab_v1.log`, `_v2.log` [read] |
| Build + first solve (mesh, assemble, factor) | **35.7 s** | **26.9 s** | same |
| Update + re-solve (value-only, same mesh) | 6.8 s | **5.8 s** (memory: ~3.7 s after in-place refactor) | same; `chec-c963ee3a` |
| Kernels per update | global_K! 1.8 s, `_update_S_values!` 0.14 s, populate_loads 0.53 s, **factorize 3.5 s**, solve + post 0.15 s | global_K! 1.0 s, populate_loads 0.02 s, **factorize 2.8 s**, solve + post 0.14 s | same |

Profile of one update (`logs/bench_asap_fea_slab_profile.txt`, 893 samples in
`_update_and_resolve!`) [read]:

| Piece | Samples | Share |
|---|---|---|
| CHOLMOD numeric refactor (`cholesky!` → `cholmod_l_factorize_p`) | 315 | 35 % |
| CHOLMOD sparse wrap + `check_sparse` | 146 | 16 % |
| `S[idx, idx]` free-DOF extraction (`_get_factorization`) | 113 | 13 % |
| `_update_S_values!` scatter | 112 | 13 % |
| `_recompute_shell_K!` (all shells) | 92 | 10 % |
| post-process (reactions) | 59 | 7 % |

So a **remesh analysis costs ~27–36 s and a value-only analysis ~4–6 s, a
factor of 4.5–9 per analysis** [read].

Remesh A/B on the same 3-floor medium office (`scripts/runners/ab_flat_fea_punching.jl`,
`max_iterations = 10`, 8 threads, busy machine) [read]:

| Variant | Elapsed | Mesher calls | Factorizations | Result | Log |
|---|---|---|---|---|---|
| current (stale mesh, update only) | **296.7 s** | 6 | 17 | converges, max punching 0.999 | `logs/ab_punch_current_10_20261102.log` |
| remesh on column growth (now production) | **536.2 s** | 26 | 18 | converges, max 0.996 | `logs/ab_punch_remesh_10_20261102.log` |
| remesh via library path | 1185.2 s | 26 | 18 | same | `logs/ab_punch_libremesh_10_20261103.log` |
| `max_iterations = 3`: current / remesh | 215.1 / 408.8 s | 6 / 20 | 15 / 15 | floors 1–2 not converged | `logs/ab_punch_current_3_…`, `ab_punch_remesh_3_…` |

Remeshing roughly **doubled** runtime on a building that needed four or five
column steps per floor. The "factorizations" counter shows 17 vs 18 because it
counts calls to `_get_factorization`, not whether the symbolic analysis was
redone (§2c). The FEA call list in the same logs shows each of the three floors
builds an **identical** first mesh (`build columns 17.0`) [read].

### 1c. Other measured hot spots

| Item | Before | After | Source |
|---|---|---|---|
| Column NLP with 108 Row F rows (Ipopt, one JuMP operator per constraint, O(nc²) evaluations) | **1249 s** | **8 s** with `_constraint_cache` | `.memory/entries/chec-03a1299d.md` [read]. **Not on this tree**: `_constraint_cache` does not appear in `SS/` [read]; it is on the `row-f-nlp` worktree |
| `_update_S_values!` indexed vs scatter map | 1.49 s | 0.135 s (11×), bit-identical | `bench_asap_fea_slab_v1.log` [read] |
| Rigid-diaphragm wall cache, 4-wall 2-story core | isolated FEM 0.016 s | reduced 0.000053 s | `.memory/entries/chec-abe8eb05.md` [read] |
| Incremental-verify profile | ~75 % in `output_hash` fingerprinting | — | `.memory/entries/deci-202e97fd.md` [read] |
| Process start for sweeps | 145 s compile + 12 s load per process; 760 s to ready 4 workers | — | `chec-c963ee3a`, `sweep_smoke_rerun.log` [read] |

---

## 2. Cost drivers

### 2a. What forces a slab remesh versus a value-only update

- **Cache key.** `FEA/cache.jl::fea_mesh_key` returns slab boundary, vertex
  list, interior edges, **every column's (x, y, c1, c2, shape, position,
  orientation)**, cell spans, target edge, drop-panel plan and span axis
  [read]. Column dimensions are in the key.
- **Where it is checked.** `FEA/precompute.jl::_build_or_update_fea!`
  recomputes the key on every analysis; a changed key calls
  `_reset_fea_cache!` and rebuilds the mesh, element data, cell→triangle map,
  median edge length, per-cell live fields and `U_D` [read].
  `SS/slabs/codes/concrete/flat_plate/pipeline/iteration.jl` (≈ line 237) also
  calls `acquire_fea_cache!` with the key, which replaces the cache for a new
  key [read].
- **Why the mesh depends on columns.** Three places [read]:
  1. `FEA/model.jl::build_slab_shell_patches` makes one `Asap.ShellPatch` per
     column of size c1×c2 with E × `patch_stiffness_factor` (default 100), and
     the mesher conforms to its outline.
  2. `FEA/model.jl::build_slab_shell_mesh` sets
     `refine_edge = clamp(min_col_dim/2, 0.04 m, target/2)`; the smallest
     column on the slab sets refinement everywhere.
  3. `FEA/model.jl::_append_flat_plate_edge_strip!` widens the edge band to
     the largest column face on each straight edge.
- **One column anywhere remeshes the whole slab.** The key holds all
  columns; the mesher (`Asap.Shell` → Delaunay + Ruppert refine) triangulates
  the slab in one pass [read; mesher detail from `deci-202e97fd`].
- **Value-only path.** `FEA/model.jl::_update_and_resolve!` changes shell
  thickness, E, column-stub sections, edge-beam sections and load, then
  `Asap.update!(model; values_only=true)` + `solve!` [read]. Thickness h is
  **not** in the key, so h steps reuse the mesh [read].
- **Column steps per slab.** Phase B (`iteration.jl::_size_flat_plate!`,
  B1 block) calls `run_moment_analysis` once per column step; budget
  `monotone_budget(max_iterations, _column_steps())`, where `_column_steps`
  is the number of `size_increment` steps (0.5 in by default) to
  `max_column_size` [read]. A 17 in column walking to 30 in is up to **26
  remeshes on that slab** [inferred from budget + increment]. Column P-M
  growth inside Phase B also forces another analysis (`pm_grew → continue`)
  [read].
- **Stale-slab loop above it.** `SY/workflow/graph_builder.jl::_design_flat_plate_members!`
  redesigns every slab whose installed column differs from the one it was
  checked at (`_stale_flat_plate_slabs`), up to 48 rounds, each round a full
  `sync_asap!` and `_reconcile_columns!` [read]. A redesign of a stale slab
  sees a new key, so it starts with a remesh [inferred].
  - **Update 2026-11-20:** this loop used to grind the full 48-round budget and
    then **throw** on the core office (two coupled bugs: the two-sided column fit
    shrank unfloored upper columns and oscillated, and `designed_supports` was
    stamped from the slab workspace's punching-minimum, which axial sizing grows
    past, so the slab stayed "stale" forever). Fixed by making the stage
    grow-only (`_floor_columns_at_installed!`) and treating a *grown* support
    column as conservatively non-stale for flat plates (§11.11.2). The loop now
    converges in a handful of rounds instead of 48, which is a large speed win on
    its own and unblocks the stage-split measurement (open Q1). See
    `docs/sizing-map/member-stage-fixpoint.md`. Opportunity #12 (re-check instead
    of redesign) is now reclassified **approximate/gated** — an exact value-only
    re-check needs the fixed mesh (#1); see the design note §4.

### 2b. Mesh size controls and typical counts

| Control | Value | Anchor |
|---|---|---|
| Target edge | `clamp(min_span/20, 0.15 m, 0.30 m)`; comment: face moments within a few percent of a 0.10 m mesh at 0.30 m and diverge by 0.50 m | `FEA/model.jl::build_slab_shell_mesh` [read] |
| Column refinement | `clamp(min_col_dim/2, 0.04 m, target/2)` | same [read] |
| Interior-edge seeding | `round(edge_len / target)` segments per interior cell edge | same [read] |
| Override | `FEA(; target_edge)` | `SS/slabs/types/analysis_methods.jl` [read] |

Typical counts [read]: medium-office floor slab 31 k nodes, 62 k triangles,
186 k free DOFs, nnz 7.8 M (`bench_asap_fea_slab_v2.log`). Core-office
analysis model 23,481 nodes, 38,887 slab and 7,504 wall triangles over 4 slabs
(`core_office_v5_design.log`; this is the post-design visualization model, so
the design meshes may differ [inferred]).

### 2c. Factorizations per round, and why

- **FEA slab.** `Asap/Model/analysis/factorization_cache.jl::_get_factorization`
  refactors in place with `cholesky!(old, K)` when `_factor_pattern_key`
  (objectid of `S`, nnz, free DOFs) matches, skipping CHOLMOD's symbolic
  analysis [read]. A value-only update keeps the pattern, so it gets
  numeric-only refactorization. **A remesh builds a new `S`**, so it pays
  symbolic + numeric [read]. Each call still extracts `S[idx, idx]` and
  re-wraps it for CHOLMOD (29 % of an update, §1b) [read].
  D/L split and per-cell live solves reuse the factor:
  `FEA/load_cases.jl` uses `update!(loads_only=true)` + `solve!` and
  `_solve_per_cell_live!` back-substitutes one RHS per cell on the cached
  factor [read]. So a slab analysis is **one factorization plus 2 + n_cells
  back-solves** [read].
- **Value-only update recomputes every shell K.**
  `Asap/Model/analysis/model_updates.jl::update!(::Model; values_only=true)`
  runs `global_K!` on all frames and `_recompute_shell_K!` on **all** shells,
  even when only a column stub section changed (10 % of an update) [read].
- **Building frame, cold path.** `SY/analyze/asap/asap/model_sync.jl::sync_asap!`
  defaults to `loads_only=false` → full `Asap.update!` → `create_S!` (new `S`
  object, factor nulled) [read]. Called once per stale-slab round
  (`graph_builder.jl::_design_flat_plate_members!`) and after each stage that
  sets `needs_sync` (`SY/workflow/execute.jl`) [read].
- **Rigid diaphragm bypasses the cache entirely.**
  `SY/…/model_sync.jl::_solve_struc_model!` routes every building solve with
  links to `Asap/Elements/rigidlink.jl::solve!(model, links)`, which forms
  `Gᵀ S G`, extracts the retained block and calls a **fresh** `cholesky`, then
  sets `model._factorization = nothing` [read]. The multi-case
  `solve(model, cases, links)` does the same again [read]. Consequences:
  - `loads_only=true` saves nothing under a rigid diaphragm: the next solve
    refactors from scratch anyway [read].
  - `SY/analyze/asap/asap/pattern_cases.jl::_solve_with_patterns!` solves the
    full load (factorization 1) then the pattern cases (factorization 2) on
    the same K; its comment "reuses cached K factorization" is not true with
    links [read].
  - These factorizations are invisible to `Asap._N_FACTORIZATIONS`
    (`docs/sizing-map/phase1-benchmarks.md` §3d) [read].
- **Section changes.** `SY/workflow/member_iteration.jl::_reanalyze_after_section_change!`
  does a full `update!` + solve + pattern refresh;
  `SY/workflow/column_reconciliation.jl::_resolve_after_column_change!` does
  `values_only` + solve + pattern refresh [read]. Under links each is 1–2
  fresh factorizations [inferred from the two items above].
- **Wall thickness.** `update_analysis!(:geometry)` calls `to_asap!`, a full
  rebuild, then restores sizes and re-solves (`model_sync.jl::update_analysis!`)
  [read]. Wall jump loops up to 4 rounds × whole member stage (README §5 #2)
  [read].
- **P-Delta.** `Asap/Nonlinear/pdelta.jl::solve_pdelta!` solves
  `(S + Kg)[idx, idx] \ F` each iteration (sparse, new factorization per
  iteration, uncached) [read]. The building path uses story geometric
  stiffness instead: `SY/analyze/lateral/interactive_checks.jl` and
  `ordinary_wall_stage.jl` call `Asap.solve(model, cases, links;
  geometric_stiffness=Kg [, exclude_shells=true])` — one fresh reduced
  factorization per call; `exclude_shells` also subtracts a re-assembled
  shell stiffness [read]. Buckling (`Asap/Nonlinear/buckling.jl`) is dense
  `K \ Matrix(-Kg)` + `eigen` [read]; not seen on the design path [inferred].
- **Building model size.** Under `:rigid`, `to_asap!` meshes walls only (no
  slab shells); slab shells enter only under `:shell`/`:semirigid`
  (`SY/analyze/asap/asap/model_builder.jl::to_asap!`) [read]. So on
  flat-plate buildings the building factorization is small next to the slab
  FEA [inferred]; on wall/lateral buildings it is not measured.

### 2d. MIP / NLP solves and P-M diagrams

- **P-M diagrams.** `SS/members/codes/aci/columns/checker.jl::_precompute_diagrams!`
  builds one diagram (20 intermediate points, `PM_DIAGRAM_N_INTERMEDIATE`)
  plus a weak-axis diagram when not square, per catalog section, threaded
  [read]. `standard_rc_columns` spans 8–36 in × 6 bar sizes × 4–16 bars
  (`SS/members/sections/concrete/catalogs/rc_columns.jl`) [read].
- **Slab stage** builds one shared cache (`SS/slabs/sizing.jl::_precompute_flat_plate_col_cache`) [read].
- **Member stage rebuilds caches per call.**
  `SY/workflow/flat_plate_column_check.jl` creates a local `caches = Dict()`
  and calls `precompute_capacities!` over the whole catalog in the stacking,
  growth, joint and reconcile functions (≈ lines 406, 522, 629, 943) — every
  call, every stale-slab round [read]. `_column_catalog(opts)` regenerates
  the catalog each call (≈ line 457) [read].
- **MIP memo misses.** `SS/optimize/solvers/discrete/model.jl` keys the memo
  on `objectid(catalog)`; the comment says a rebuilt catalog is a miss [read].
  The memo is capped at 64 entries and cleared wholesale
  (`SS/optimize/solvers/discrete/cache.jl`) and bypassed when tracing [read].
- **Counts.** Beam ⇄ column loop: 2 MIPs + 2 rebuilds per pass, up to 20
  passes (README §5 #3) [read]. Flat-plate Phase B: one `size_columns` per
  step (`iteration.jl` B1) using the shared cache [read]. No log counts MIP
  solves on the FEA buildings (open question 3).
- **NLP.** `SS/optimize/solvers/continuous_nlp.jl` multi-starts Ipopt with
  `Threads.@spawn` [read]; the O(nc²) constraint evaluation (1249 s case) is
  unfixed on this tree (§1c).

### 2e. Recomputed although invariant during sizing

| What | Recomputed when | Anchor | Tag |
|---|---|---|---|
| Whole slab mesh, cell→triangle map, edge length | any column in the slab grows | `FEA/precompute.jl::_build_or_update_fea!` | read |
| Identical first meshes on typical floors | once per slab index; cache keyed by `slab_idx`, not by key content | `iteration.jl` (`struc._analysis_caches[slab_idx]`); `ab_punch_*` logs | read |
| All shell element K | every value-only update, even column-only changes | `Asap/…/model_updates.jl::update!` | read |
| Free-DOF submatrix + CHOLMOD wrap | every refactor | `factorization_cache.jl::_get_factorization` | read |
| Rigid-link `G`, `GᵀSG` pattern, symbolic factor | every building solve | `rigidlink.jl::solve!`, `solve` | read |
| Column catalog and P-M diagrams | every member-stage helper call | `flat_plate_column_check.jl` | read |
| Building `S` | every `sync_asap!` with default `loads_only=false` | `model_sync.jl::sync_asap!` | read |
| Building model (walls) | every wall-thickness change (`to_asap!`) | `model_sync.jl::update_analysis!` | read |
| Compiled code | every new process (prepare 50–140 s) | logs §1a | read |

### 2f. Parallelism today

- `SS/slabs/sizing.jl::size_slabs!` spawns slabs in conflict-free batches
  [read], but `design_building` goes through the design graph, which **pins
  slabs to sequential `eachindex` order** for determinism
  (`SY/workflow/graph_builder.jl::build_design_graph` docstring) [read].
- Inside Asap: element K, scatter map, and shell assembly are
  `Threads.@threads` (`Asap/Model/preprocessing/*.jl`) [read]. CHOLMOD uses
  BLAS threads for supernodal work [inferred].
- Member checkers (`checker.jl`, `binary_search.jl`, demands per group) are
  threaded [read].

---

## 3. Opportunities (ranked)

Expected factor is on the stage named, not the whole run, unless stated.
"Exact" = same results bit-for-bit or to solver tolerance. "Approx + verify" =
fast tier, the full tier confirms. "Structural" = changes what is computed;
needs sign-off per `code-accuracy.mdc` where noted. "Has today" says what the
code already does.

| # | Idea | Type | Expected factor | Evidence | Anchor | Has today | Risk |
|---|---|---|---|---|---|---|---|
| 1 | **Fixed slab mesh, column patch as stiffness** (plan 7.4). Mesh once per slab with a fenced fine zone around each column sized for the cap + d/2; column growth re-tags patch triangles / sets patch E and stub section, never remeshes | Exact w.r.t. a fixed mesh; approximate w.r.t. today's conforming remesh | **4.5–9× per Phase B analysis; ~1.8–2× whole FEA run** at 4–5 steps/floor; more on cap walks (66-min, 1686 s runs) | build 27–36 s vs update 4–6 s; A/B 536 s vs 297 s | `FEA/cache.jl::fea_mesh_key`, `FEA/model.jl::build_slab_shell_patches`, `::build_slab_shell_mesh` | Update path exists; key forces rebuild by design (`deci-202e97fd`) | Patch edge jagged at 0.15–0.3 m vs 0.5 in steps (deci-202e97fd rejected naive re-tagging); needs a fine fenced zone (~1 in) and a gate vs full remesh on punching ratios (1–3 % demand shift measured) |
| 2 | **Low-rank (Woodbury) or static-condensation update for column-only changes**, on top of #1. A stub section change is rank ≤ 6 per column (one end fixed); a patch re-tag is rank ≈ 3 × nodes in the changed annulus | Exact (to round-off); refactor every k updates | **5–20× per Phase B analysis** vs numeric refactor (factor 2.8 s vs solve 0.14 s; rank-r update costs ~r back-solves) | §1b kernels | `Asap/Model/analysis/factorization_cache.jl::_get_factorization` (new Asap entry point), called from `FEA/model.jl::_update_and_resolve!` | Numeric-only refactor already reuses symbolic analysis | Conditioning with E×100 patches; rank grows with accumulated changes; must live in Asap (architecture-contracts) |
| 3 | **Predict-then-confirm punching** (plan-b10cde0c item 5): secant demand from last two confirms picks the next trial; if the cap fails, jump to cap + thickening | Approx + verify (confirm analysis and §11.11.7.1 check still decide) | **3–10× fewer Phase B analyses** on long walks (26 → 3–5) | 1686 s and 66-min runs both walked corner columns to the 30 in cap | `iteration.jl::_size_flat_plate!` Phase B; `pipeline/punching_resolution.jl::_resolve_punching_failures!` | Wall jump already predicts then confirms | Overshoot by one increment; needs user sign-off on predictor policy (plan-b10cde0c open decision) |
| 4 | **Content-addressed FEA cache**: key the mesh (and factor) by `fea_mesh_key` content, not `slab_idx`; memo the whole slab result on (key, h, E, stub sections, loads) | Exact | up to **n_typical_floors×** on builds (3 identical first builds in A/B logs); full skip when a stale slab's inputs are unchanged | `ab_punch_*` FEA call lists | `iteration.jl` cache acquisition; `FEA/cache.jl::acquire_fea_cache!` | Per-slab cache persists across `design_building` calls on one `struc` | Memory (one 186 k-DOF factor per distinct key); must stay a pure function of declared inputs (plan-2d4158d0 item 5) |
| 5 | **Coarse-mesh fast tier** (F.4): target edge 0.6 m for exploration, 0.30 m (or finer near columns) for verification | Approx + verify | **~4× fewer DOFs → ~5–8× per factorization, ~4× meshing** [inferred: 2-D nested dissection ~N^1.5] | mesh controls §2b; code comment says moments diverge by 0.50 m | `FEA/model.jl::build_slab_shell_mesh` (`target_edge`) | `FEA(; target_edge)` override exists | Punching demand near columns is mesh-sensitive; band must be measured per F.4 |
| 6 | **Superposition of unit load cases per geometry** for fast slab demands: unit D, per-cell unit L, unit column-moment cases on one factor; candidates scale demands without re-analysis | Approx + verify (h and column stiffness change relative stiffness) | **10–50× per trial** in the fast tier [inferred] | Per-cell live + D/L split already share one factor | `FEA/load_cases.jl::_solve_dl_cases!`, `::_solve_per_cell_live!` | D/L and per-cell live superposition exist (`pattern_mode = :fea_resolve`; default `:efm_amp`) | K(h) = t³K_b + tK_m + K_stub is not a scalar multiple, so h trials are approximate; bound with confirm |
| 7 | **Rigid-link solve cache in Asap**: keep `G`, the `GᵀSG` sparsity and the CHOLMOD symbolic factor; numeric refactor on value changes; reuse the numeric factor for `loads_only` and for full-load + pattern multi-case | Exact | **2× on pattern solves; 1.3–3× per building solve** [inferred]; total impact unmeasured | `rigidlink.jl::solve!` nulls the factor; `_solve_with_patterns!` factors twice | `Asap/Elements/rigidlink.jl::solve!`, `::solve`; `SY/…/pattern_cases.jl::_solve_with_patterns!` | `loads_only` plumbing exists but is moot under links | Small on flat-plate buildings (building model small); possibly large on wall/lateral (SDC 434–988 s) — measure first |
| 8 | **Cheaper refactor plumbing**: keep a persistent free-DOF CHOLMOD matrix and scatter into it directly (skip `S[idx,idx]` + `check_sparse`); skip shell `global_K!` when only frames changed; scale shell K by t³/t on uniform h change | Exact | **1.3–1.6× per value-only update** (29 % + 10 % of samples) | §1b profile | `factorization_cache.jl::_get_factorization`; `model_updates.jl::update!` | Scatter map landed (11×) | Low; keep the snapshot/deepcopy contract (no pointer-holding fields, `chec-c963ee3a`) |
| 9 | **Persistent workers / sysimage** for sweeps and the exploration tier | Exact | **10–40× on small (DDM, steel) cases**; ~150 s saved per process | warm 3.75 s vs cold 145 s; 760 s worker start | `scripts/api/build_sysimage.jl`; `scripts/runners/test_server.jl` pattern | Sysimage script and test server exist | Sysimage rebuild on source change |
| 10 | **Hoist P-M caches and memo catalogs** (plan 7.1): one capacity cache per (catalog, material, objective) for the whole run; catalog generated once; MIP memo keyed on catalog value | Exact | 1.5–3× on member stage [inferred]; matters most on DDM/fast tier where MIP is 63 % | README §5 #5; `chec-c963ee3a` | `SY/workflow/flat_plate_column_check.jl` (local `caches`, `_column_catalog`); `SS/optimize/solvers/discrete/model.jl` memo key | Slab stage shares one cache | Cache invalidation if catalog options change mid-run |
| 11 | **Land the Ipopt constraint cache** on main | Exact (bit-identical per memory) | **~150×** on NLP column sizing with many rows (1249 → 8 s) | `chec-03a1299d` | `SS/optimize/solvers/continuous_nlp.jl::_optimize_ipopt` | Only on `row-f-nlp` worktree | Merge with the other session's checker refactor |
| 12 | **Re-check instead of redesign in the stale-slab loop**: when a column only grew, re-run the slab checks on a value-only (or #2 low-rank) analysis instead of the full floor design | Structural (order of decisions) | 2–5× on the member stage of flat-plate buildings [inferred] | README §5 #1; loop budget 48 | `SY/workflow/graph_builder.jl::_design_flat_plate_members!` | Loop exists, redesigns from scratch | A larger column can lower h; a re-check would keep the thicker slab (ratchet) unless h may shrink |
| 13 | **Parallel slabs** across floors and within a floor (generalize the propose-on-private-copy two-pass used for shared columns) | Structural for ordering; exact if made order-independent | **1.5–3× on slab stage** [inferred; CHOLMOD already uses threads] | graph pins `eachindex`; `size_slabs!` batches exist | `SY/workflow/graph_builder.jl::build_design_graph`, `::_push_two_level_slab_nodes!` | Two-pass for shared columns on one floor | FEA reads `column_above` stubs, so floors are coupled; determinism contract |
| 14 | **Parallel benchmarks / sweeps** across processes | Exact | ≈ cores / (threads per job) | sweep runner: 4 cases 1598 s wall | `scripts/runners/time_building_sweep.jl`, sweep driver | Multi-worker sweep exists | Memory per worker with 186 k-DOF factors |
| 15 | **Wall thickness updates in place** (plan 7.2) instead of `to_asap!` | Exact | removes 1 rebuild per wall round (≤ 4) [inferred] | README §5 #2 | `SY/analyze/asap/asap/model_sync.jl::update_analysis!` (`:geometry`) | Mat Winkler path mutates in place | Mesh topology must not change with t |
| 16 | **Cheaper capture / fingerprinting** | Exact | capture 13–58 s per run; `output_hash` ~75 % of incremental-verify profile | §1a, `deci-202e97fd` | `SY/core/snapshot.jl`, capture path | — | Hash must stay authoritative (architecture-contracts) |
| 17 | **Cross-run caching** (typical bays, layout fingerprints): persist mesh + symbolic factor + slab results keyed by geometry fingerprint across processes | Exact | 1 build saved per repeated layout; large for sweeps over loads/materials on one layout [inferred] | builds 27–36 s each | `FEA/cache.jl` (key), new on-disk store | In-process persistence only | CHOLMOD factors are pointer objects (never snapshot them, `chec-292afb50` R1); store mesh + ordering, not the factor |

Notes on ideas the brief asked about:

- **Symbolic reuse with numeric refactorization** already exists for the
  slab FEA (`_get_factorization` → `cholesky!`), so that part is done for
  value-only updates. It does **not** help a remesh (new pattern) and is
  absent for rigid-link building solves (#7).
- **Superposition of unit load cases** exists for D/L and per-cell live
  loads on one factor. Extending it to column-moment and h trials is the
  fast-tier idea (#6), approximate.
- **Column-size-independent mesh**: the cheapest version is #1 with
  `refine_edge` fixed from the column cap instead of the current smallest
  column, plus edge bands sized from the cap; then only patch tags and stub
  sections change.

New levers found 2026-11-20 (profiler-driven; `chec-4ffcbf9e`):

- **#18 — one building re-solve per member-stage round.** The member settle
  loop re-solves the building frame after *each* column change
  (`_resolve_after_column_change!` inside `check_flat_plate_columns!`'s own
  settle), so a round that grows several columns pays several fresh rigid-link
  factorizations. Batch a round's column grows and re-solve once at round end.
  Exact *iff* the converged state is unchanged (it re-solves at round end
  anyway); needs a convergence-equivalence proof since it reorders decisions.
  Attaches to `graph_builder.jl::_design_flat_plate_members!` /
  `flat_plate_column_check.jl::check_flat_plate_columns!`. Pairs with #7.
- **#19 — unify the member-stage and slab-stage P-M catalog caches.** #10's
  memo (`flat_plate_column_check.jl`) and the slab stage's
  `StructuralSizer._precompute_flat_plate_col_cache` build the same catalog
  diagrams independently. One run-level cache keyed by (catalog, material,
  objective) shared across both stages removes the duplicate precompute. Exact.
- **#20 — resolve `_rc_section_check` against the full-catalog cache.** Idea A
  memoizes a 1-section cache; if the installed section is a catalog section
  (it is, when picked from the catalog), index into the already-built
  full-catalog diagram instead of building one. Exact; a refinement of #10.

---

## 4. Open questions and measurements needed

1. **Where do the core office's 699 s of `pipeline` go?** **Answered
   2026-11-20** (`scripts/runners/profile_design_building_stages.jl`, `SizingProbe`,
   on the now-converging core office; busy machine so read the *relative* split,
   not the absolute seconds). `pipeline` splits by stage (building-frame vs other
   = slab-mesh / story-shell / wall factorizations):

   | stage | time(s) | bldg fac / refac / rhs | other fac / refac |
   |---|---|---|---|
   | `ordinary_walls` | **709** | 28 / 0 / 60 | 7 / 10 |
   | `members` | **594** | 16 / 3 / 15 | 6 / 10 |
   | `slab_sizing_s1` | 374 | 0 / 0 / 0 | 1 / 4 |
   | `slab_sizing_s2–s4` | 46 / 29 / 29 | 0 | ~1 / ~3 each |
   | `foundations` | 70 | 2 / 0 / 2 | 0 |
   | TOTAL | 1850 | 48 / 3 / 79 | 19 / 34 |

   Reading: the two heavy stages are **walls (709 s)** and **members (594 s)**,
   and both are dominated by **building-frame full factorizations** (28 + 16 = 44
   of the 48 total). Under the rigid diaphragm every building solve refactors
   from scratch (`rigidlink.jl::solve!` / `solve` null the factor; §2c), so those
   44 fresh factorizations are the single largest recoverable cost — this is the
   quantitative case for **#7 (rigid-link factorization cache)**, now the top exact
   target. The member stage also pays **6 full + 10 numeric slab remeshes**
   in-stage (stale-slab redesign), the case for #4/#1. The P-M / catalog compute
   that #10 (landed 2026-11-20, exact) removed is *not* a factorization and so is
   invisible to this probe; it lives inside the `members` 594 s alongside the
   factorizations. Full report: the `==== SIZING PROBE REPORT ====` block of
   `logs/profile_stages_overnight.log`.

   **#7 implementation note / obstacle (for sign-off).** The mutating
   `solve!(model, links)` (member-stage building solves) can cache on `model`:
   store `G`, `dependent`, `retained_free`, and the reduced CHOLMOD symbolic
   factor keyed on the link set + `S` sparsity pattern, then numeric-only
   `cholesky!` on value changes — exactly the proven-exact pattern the slab FEA
   already uses (`factorization_cache.jl::_get_factorization`). The multi-case
   `solve(model, cases, links)` (the walls' 28 factorizations + 60 RHS) is
   **non-mutating by contract** ("does not write `model._factorization`"), so its
   cache has no clean home on `model`; it needs either a passed-in cache handle
   or a contract change. Because this is the core, safety-critical analysis path,
   it is left for explicit sign-off rather than an autonomous rewrite.
2. **How many remeshes, value-only updates and column steps per slab in the
   66-min run?** `FEAModelCache.n_rebuilds` / `n_updates` are written on
   `size_flat_plate!` exit (`chec-cda68f1e`); extract them per slab, and keep
   the log in `logs/` (none exists today).
3. **MIP / NLP solve counts and P-M cache builds per stage** on the FEA
   buildings. `_DISCRETE_MEMO_HITS` and `_RC_NLP_MEMO_HITS` exist; misses and
   `precompute_capacities!` calls are not counted.
4. **Rigid-link factorization cost.** How many building solves per run, and
   their size, on the SDC wall/lateral buildings (434–988 s)? Today's counter
   cannot see them.
5. **Fixed-mesh accuracy band.** Punching ratio and face moments of #1 vs
   full remesh on the medium office and 3×3 plate; acceptance tolerance is a
   user decision (code-accuracy).
6. **Coarse-mesh band** for #5 at 0.45 / 0.6 m vs 0.30 m, per F.4, and
   whether punching demand can come from a local fine patch on a coarse
   global mesh.
7. **CHOLMOD threading** under Julia `-t 8`: is BLAS threading active during
   supernodal factorization, and does slab-level parallelism (#13) contend
   with it?
8. **Is `prepare` all compilation?** Second-call `prepare` is ~0.05 s, but
   the 50–140 s first call has not been split into compile vs tributary /
   geometry work.
9. **Woodbury rank in practice** (#2): how many patch triangles change per
   0.5 in column step on a ~1 in fenced zone; when to refactor.
