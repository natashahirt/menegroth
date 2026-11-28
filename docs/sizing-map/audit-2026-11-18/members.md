# Members re-audit 2026-11-18 — columns and beams (RC, steel)

Scope: SS `members/` (ACI columns incl. `pm_rect/`, `floor_transmission.jl`;
ACI beams incl. `checker/` split, `joist_construction.jl`, `shell_deflection`;
AISC checker incl. `cache.jl`, `composite_feasibility.jl`; `members/optimize/`
discrete MIP + NLP), SY `analyze/members/`, SY `workflow/member_iteration.jl`,
`check_settle.jl`, `flat_plate_column_check.jl`, `column_reconciliation.jl`,
row-F floors in `analyze/lateral/interactive_checks.jl`.

Baseline: `../raw/members.md` (2026-11-11). Audited the working tree on
`main` (HEAD `7236704d` plus a large uncommitted / untracked diff: e.g.
`flat_plate_column_check.jl` +846 lines vs HEAD, new untracked
`members/optimize/api/`, `members/optimize/problems/`,
`optimize/solvers/discrete/`) [read: `git status`, `git diff --stat`].

Abbreviations: SS = `StructuralSizer/src`, SY = `StructuralSynthesizer/src`.

---

## 1. Changes since 2026-11-11

### 1.1 Reported changes — verification

| # | Reported change | Verdict on `main` working tree | Evidence |
|---|---|---|---|
| 1 | RC column groups sized on concurrent case rows, not the group envelope | **Partly.** Case rows are checked, but the envelope row is **still** in every set. This was already true on 11-11 (baseline Top-5 #5: "RC columns already also check per-case rows"). The commit with this title (`79fa0474c`) is on the unmerged branch `row-f-nlp`. | [read] `SY/analyze/members/members/size_columns.jl::_rc_column_demand_sets` — "The envelope row and every pattern case are both included"; [read] `git branch --contains 79fa0474c` → `row-f-nlp` only, not an ancestor of HEAD |
| 2 | Row-F floors relax to any section that passes the stored rows | **Not on main.** Floors are still objective-sorted catalog masks that never relax. Commit `09beee105` is on `row-f-nlp` only. | [read] `SY/analyze/members/members/size_beams.jl::_frame_floor_mask` (floor section + every section with objective strictly greater); [read] `SY/analyze/lateral/interactive_checks.jl::_raise_frame_floors!` walk starts at `o_now` = heaviest current objective |
| 3 | Story-shell trim runs once after later rounds settle | **Not on main.** Trim runs only inside the first `size_beams_with_story_shell!` call (`!continuing`). Rounds 2–3 never trim. When options are checkable, round 2+ does not run at all: the loop breaks to `_reconcile_shell_frame!`. Commit `c3593a1eb` is on `row-f-nlp` only. | [read] `SY/analyze/members/members/size_beams_story_shell.jl::size_beams_with_story_shell!` (`if ratchet && trim && !continuing && r.converged`); [read] `SY/workflow/member_iteration.jl::_size_with_story_shell!` (`checkable && break`); no other `trim` call in SY |
| 4 | Check-based settle when the beam/column loop cycles | **Verified.** On a repeated section state the cycle states are reinstalled, re-analysed and checked; the cheapest all-passing state wins. Otherwise a per-group "mixed" state is tried, then up to 3 rounds resize only groups that fail. | [read] `SY/workflow/check_settle.jl::_check_settle!`, `_resize_failures!`, `_beam_group_report`, `_column_group_report`; commit `fb22f148` (main) |
| 5 | Story shell reconciled with the sections the frame kept | **Verified.** Shell solved on the installed sections; passing groups keep their section; failing beams are resized on the fresh shell; columns are re-picked and passing ones restored (unless uniform sizing is on). Up to 4 attempts, stops on a repeated state. | [read] `SY/workflow/check_settle.jl::_reconcile_shell_frame!`, `_resize_rejected!`, `_restore_passing_columns!`; commit `51020479` (main) |
| 6 | Stale frame stiffness fixed in story-shell beam sizing | **Verified.** Every story-shell sizing call re-assembles and re-solves the frame on the sections it wrote. | [read] `SY/analyze/members/members/size_beams_story_shell.jl::_size_story_beams!` → `SY/workflow/member_iteration.jl::_reanalyze_after_section_change!` (`Asap.update!`, solve, `_refresh_pattern_solve_cache!`) |
| 7 | Steel Cm uses frame curvature and span load | **Not on main.** `member_group_demands` does extract signed FEA end moments for **all** column groups, but the steel column path passes only `Pu, Mux, Muy, Pu_t` arrays, so `MemberDemand` falls back to `M1 = 0` → `Cm = 0.6`. Beam groups never get `M1/M2`; `transverse_load = false` everywhere. Commit `338657c9d` is on `row-f-nlp` only. | [read] `SY/analyze/members/members/size_columns.jl::_size_columns_impl!` (steel: `StructuralSizer.size_columns(Pu, Mux, geometries, opts; Muy, Pu_t)`); [read] `SS/members/optimize/api/columns.jl::size_columns` (steel array overload builds `MemberDemand` without `M1x/M2x`); [read] `SS/members/types/demands.jl::MemberDemand` (default `M1 = 0`); [read] `SY/analyze/members/members/demands.jl::member_group_demands` (`transverse_load=false`; non-columns leave M1/M2 unset) |
| — | (scope note) RC objectives count longitudinal steel and ties/stirrups | **Not on main for the discrete MIP.** RC column and RC beam `objective_value` (all objectives) use gross `b·h` only. The RC NLP objectives weight longitudinal ρ (columns: MinWeight/MinCost/MinCarbon; beams: MinWeight), with no ties/stirrups. Commits `b547e6fd2`, `2ad0cbf32` are on `row-f-nlp` only. | [read] `SS/members/codes/aci/columns/checker.jl::objective_value`, `_precompute_diagrams!`; [read] `SS/members/codes/aci/beams/checker/checker_objectives.jl::objective_value`; [read] `SS/members/optimize/problems/rc_column.jl::objective_fn`, `.../problems/rc_beam.jl::objective_fn` |

`row-f-nlp` is 22 commits ahead and 184 behind `main`; it is checked out
in a prunable worktree at `/private/tmp/menegroth-rowf` [read: `git
worktree list`, `git rev-list --count`]. Merging it would change items 1, 2, 3, 7
and the objectives. Those claims were checked against commit titles and
`--stat` only, not against the diffs [read titles/stats].

### 1.2 Other changes found (not in the reported list)

- **Flat-plate columns are no longer grow-only.** [read]
  `SY/workflow/flat_plate_column_check.jl::check_flat_plate_columns!` now
  calls only `_fit_flat_plate_columns!`. It binary-searches catalog plan-size
  groups (`_lightest_passing_group`) for the lightest section passing full-load
  P-M, the ACI 318-11 §10.12 joint check, and punching at the trial plan size
  (`check_punching_for_column` on the stored slab demands). With
  `uniform_column_sizing === :off` and stored punching demands, the search has no
  floor at the current size. The stacking rule is gone ("A column is not
  required to be at least as large as the column above it"). The old
  `_stack_flat_plate_columns!` and `_grow_flat_plate_columns!` are still
  defined but have no callers [read: grep]. This retires baseline Top-5 #1 in
  part (see §3 L-FP2, §6 S1).
- **Flat-plate member stage now records reanalysis floors.** [read]
  `SY/workflow/graph_builder.jl::_design_flat_plate_members!` keeps
  `floors::Dict{Int,Tuple}`. `_raise_column_floors!` records a plan size
  whenever a stale-slab redesign grew a column during that round. The fit search
  never goes below it.
- **Inner story-shell cycles are now check-settled.** [read]
  `SY/analyze/members/members/size_beams_story_shell.jl::_story_shell_passes!`
  → `SY/workflow/check_settle.jl::_check_shell_settle!` (commit `def4efb9`).
- **Rectangular RC beams join the story-shell ratchet.** [read]
  `_shell_ratchet_ok` now admits rectangular discrete concrete; T-beams are not
  floored (commit `9ef38636`; `member_iteration.jl::_size_with_story_shell!` comment).
- **Joist construction (ACI 318-11 §8.13).** [read]
  `SS/members/codes/aci/beams/joist_construction.jl`: rib geometry limits
  §8.13.2/.3, slab thickness §8.13.5.2/§8.13.6.1, and the 1.10·Vc factor of
  §8.13.8 when the limits are met (`_checker_vc_factor` in
  `checker/checker_strength.jl::_compute_φVn_max`).
- **Story-shell deflection check on beams.** [read] ACI beams push
  `shell_deflection` (ACI 318-11 §9.5.2) from `checker/checker_types.jl`, and steel
  beams use `SS/members/codes/aisc/checker/shell_deflection.jl::_steel_shell_ratio`.
- **Still present from baseline:** steel harmonize copies the governing
  member's `volumes` (area × its own length) onto every member
  [read `member_iteration.jl::_harmonize_steel_group!`]. The
  rectangular-column reconcile still compares each side to `sqrt(Ag_req)`
  [read `column_reconciliation.jl::_reconcile_columns!`]. In the flat-plate path,
  the later `_fit_flat_plate_columns!` can now undo that over-growth
  [inferred].

---

## 2. Flow

### 2.1 Entry and dispatch

[read] `SY/workflow/member_iteration.jl::_size_beams_columns!` dispatches as follows:

1. Slabs are all flat plate / flat slab / grade / roof →
   `SY/workflow/graph_builder.jl::_design_flat_plate_members!` (§2.3).
2. No `:beams` edges → columns-only loop (`size_columns!` → harmonize →
   fire coating → `update_analysis!(:stiffness)`, until sections repeat;
   `max_iterations`).
3. Story-shell levels present → `_size_with_story_shell!` (§2.4). Otherwise
   `_iterate_beams_columns!` (§2.2).

The pipeline then runs walls and row F. `SY/workflow/pipeline_spec.jl::_walls_with_member_recheck!`
re-runs the whole member stage (≤4 rounds) when wall thickness jumps, a
row-F floor is added, or `_floor_overstressed_frame_columns!` floors an
RC frame column at its current section [read].

### 2.2 Beam ↔ column loop (`_iterate_beams_columns!`) [read]

Each pass:
1. `size_beams!` with frame demands (`member_group_demands`, full frame FEA
   plus pattern cases) or held shell demands. Beams get
   `section_floor = _section_floors(struc)` when `upward_only`.
2. Rib and solid-head adjustments: `raise_head_face_ribs!`,
   `conform_rib_lines!`, `grow_building_solid_heads!`.
3. `_sync_fire_coating_loads!` → `update_analysis!(:stiffness)`.
4. `size_columns!` (fresh MIP for every group) → `_harmonize_columns!` →
   coating → `update_analysis!(:stiffness)`.
5. Converged when no beam or column section changed. If the state equals an
   earlier one, `_check_settle!` runs (§3 L-BC). Otherwise the loop continues
   until `max_iterations`, then returns `converged = false`.

### 2.3 Flat-plate member stage (`_design_flat_plate_members!`) [read]

1. `_reconcile_columns!`:
   `_install_sized_column_frame!` → axial growth to ACI 318-11 Eq. (10-2) at
   ρg = 0.01 from frame `Pu` (`_column_asap_Pu`; grow-only) →
   `check_flat_plate_columns!` (settle loop of `_fit_flat_plate_columns!` with
   re-solve after each change).
2. `_harmonize_columns!` (max c1, max c2 per story or building).
3. `settle!` loop (budget `monotone_budget(max_iterations, 48)`): find slabs
   not checked at the installed columns (`_slab_checked_at_installed_columns`,
   exact equality on c1/c2/shape of supports and the column above) → redesign
   those slabs (`_isolated_floor_outcome`, slab area) → `_apply_support_envelope!`
   (`_support_beats`: a proposal may not shrink either side) →
   `_raise_column_floors!` → `sync_asap!` → `_reconcile_columns!` →
   harmonize. Running out of budget raises an error.

### 2.4 Story-shell path (`_size_with_story_shell!`, `max_rounds = 3`) [read]

Round r:
1. `size_beams_with_story_shell!`:
   a. `_size_story_beams!` on frame demands (tributary area loads on the frame
      model). Frame re-solve.
   b. `_story_shell_passes!` (≤10 passes). Each pass: `_gather_shell_demands!`
      (`build_story_shell` cached per level in `shells`, then `solve_story_shell!`,
      service solve when on) → `_size_story_beams!` → re-solve. The ratchet
      starts after `free_passes = 2`, or at once when continuing. A repeat →
      `_check_shell_settle!`.
   c. Round 1 only: `_trim_story_shell!`.
2. `_iterate_beams_columns!` with those shell demands held and `upward_only`.
3. Held = shell converged, service converged, and beams and columns unchanged by step 2.
   If not held: seed the next round. When `checkable`, break and run
   `_reconcile_shell_frame!` (≤4 attempts). Otherwise run rounds 2–3 with
   `floor = _section_floors(struc)`.

### 2.5 Sizing calls (SS)

- **Discrete** [read] `SS/optimize/solvers/discrete/model.jl::optimize_discrete`:
  memo lookup (`_DISCRETE_SOLVE_MEMO`, 64 entries, key includes
  `objectid(catalog)`) → `create_cache` + `precompute_capacities!` when no
  cache is passed → threaded feasibility screen (`is_feasible` for every
  group × section) → JuMP binary model (HiGHS / Gurobi) → `optimize!`.
- **RC column feasibility** [read]
  `SS/members/codes/aci/columns/checker.jl::is_feasible` works on cached P-M
  diagrams (`_precompute_diagrams!`: `generate_PM_diagram` per catalog section,
  plus a y-axis diagram for non-square sections when biaxial is on), with
  slenderness via `Cm = 0.6 − 0.4·M1/M2` from signed end moments.
- **Steel feasibility** [read]
  `SS/members/codes/aisc/checker/steel_feasibility.jl::is_feasible`: §H1.1
  H1-1a/b with App. 8 B1 (Eqs. A-8-1/A-8-3), hogging Chapter F (§F2.2, Lb = L,
  Cb = 1). B2 is not applied (`@warn` when `braced = false`). Composite:
  `composite_feasibility.jl::is_feasible` (Chapter I, §I3.1b, §I3.2b,
  §I8.2c; deflection Eq. C-I3-5).
- **NLP** [read] `SS/members/optimize/api/rc_columns_nlp.jl`,
  `problems/rc_column.jl`, `problems/rc_beam.jl`, `w_column.jl`, `hss_column.jl`,
  `w_beam.jl`, `hss_beam.jl` (Ipopt via `objective_fn`). Row-F floors refuse
  NLP (`_refuse_frame_floors`).

---

## 3. Loops

| id | anchor | iterates | budget | growth | converges when | writes | ratchet? |
|---|---|---|---|---|---|---|---|
| L-BC | `SY/workflow/member_iteration.jl::_iterate_beams_columns!` | beam.section, column.section | `params.max_iterations` | **free** (fresh MIP each pass); beams **grow-only** when `upward_only`; floors from row F | no section changes; a repeated state → `_check_settle!` | beam.section, column.section, model stiffness | No for columns [read]. Yes for beams under `upward_only` (§3 L-SS) |
| L-CS | `SY/workflow/check_settle.jl::_check_settle!` | cycle states, then resize of failing groups | cycle length + 1 mix + 3 resize rounds | **free+guard**: pick the cheapest all-passing state; else resize only the failing groups | every beam and column group passes the analysis of its own installed sections | beam.section, column.section | No [read]. Columns are re-picked by `size_columns!` in `_resize_failures!` |
| L-CO | `member_iteration.jl::_size_beams_columns!` (no-beam branch) | column.section | `max_iterations` | free | sections identical | column.section | No [read] |
| L-SR | `member_iteration.jl::_size_with_story_shell!` | rounds of shell + frame | `max_rounds = 3` | beams **grow-only** after round 1 (`floor = _section_floors`) when not checkable; when checkable, exits to L-RSF | held (see §2.4) | beam.section, column.section | **Yes** for beams in the non-checkable path; rounds 2–3 have no trim [read] |
| L-SP | `size_beams_story_shell.jl::_story_shell_passes!` | beam.section vs shell demands | `max_passes = 10` | free for `free_passes = 2`, then **grow-only** (`_section_floors`) | sections held, region shift ≤ 0.05, service on | beam.section | **Yes**; the round-1 trim partly undoes it [read] |
| L-TR | `size_beams_story_shell.jl::_trim_story_shell!` | one free pick, then upward passes | one L-SP run | free+guard (kept only if converged and objective lower) | — | beam.section | Mitigates L-SP, first call only [read] |
| L-SS | `check_settle.jl::_check_shell_settle!` | inner-pass cycle states | cycle length | free+guard | all states checked against own shell | beam.section | No [inferred] |
| L-RSF | `check_settle.jl::_reconcile_shell_frame!` | failing beam/column groups | `attempts = 4` | **free+guard**: passing groups keep their section (sticky); failing groups re-picked | shell regions ≤ tol, service converged, all groups pass | beam.section, column.section | Passing columns are restored, not re-picked lighter (sticky, not grow-only) [read `_restore_passing_columns!`] |
| L-FP | `graph_builder.jl::_design_flat_plate_members!` | stale slabs ↔ columns | `monotone_budget(max_iterations, 48)` | slab-side **grow-only** (`_support_beats`); column side free above `floors` | no stale slab | slab design, column.c1/c2/section, `floors` | `floors` persist for the call (see L-FP2) [read] |
| L-FP2 | `flat_plate_column_check.jl::check_flat_plate_columns!` | column.section | `monotone_budget(max_iterations, |catalog|)` | **free** above `floors` when `uniform_column_sizing === :off` and punching demands are stored; else **grow-only** (floor = current c1, c2) | a round changes nothing | column.c1/c2/section, frame section | `floors` from `_raise_column_floors!` record the size an earlier slab analysis needed. That analysis was run at a smaller slab, and the floor outlives it [inferred] |
| L-RC | `column_reconciliation.jl::_reconcile_columns!` (axial step) | — (one pass) | 1 | **grow-only** | — | column.c1/c2 | No longer persists in the flat-plate path: L-FP2 can shrink afterward [read/inferred] |
| L-H | `member_iteration.jl::harmonize_uniform_column_sizes!` | — | 1 | **max** (RC: max c1, max c2 independently; steel: max area) | — | column.c1/c2/section | Recomputed after each fresh `size_columns!`, so it does not ratchet across passes in L-BC. It does pin shrink off in L-FP2 [read] |
| L-WM | `pipeline_spec.jl::_walls_with_member_recheck!` | walls ↔ member stage | `max_rounds = 4` | grow-only (wall t, floors) | thickness, floors and sections unchanged | wall.t, frame floors, all member sections | **Yes**: `frame_section_floors` persist on `struc` [read] |
| L-RF | `interactive_checks.jl::_raise_frame_floors!` | catalog walk per failing group/cohort | catalog length | **grow-only** (starts at heaviest current objective in the cohort) | first section passing all row-F rows | `struc.frame_section_floors` | **Yes**, never relaxed on main [read] |
| L-OS | `pipeline_spec.jl::_floor_overstressed_frame_columns!` | — | 1 per L-WM round | **floor at the current (failing) section** | — | `struc.frame_section_floors` | **Yes** [read]; checks `frame_column_demand(envs[i])`, the envelope, not case rows [read] |

---

## 4. Writers

### column.section / column.c1, c2

| writer | rule | path |
|---|---|---|
| `SY/workflow/prepare.jl` → `size_columns.jl::estimate_column_sizes!` | seed (tributary estimate) | all [read] |
| Flat-plate slab loop (slab area: column P-M step, `column_updates.jl`) | grow-only per dimension, `max(c_span_min, c_pm, c_old)` | flat plate, stage 1 [read baseline; not re-read] |
| `graph_builder.jl::_apply_support_envelope!` | max over slab proposals (`_support_beats`) | flat plate [read] |
| `column_reconciliation.jl::_reconcile_columns!` | grow (axial Eq. 10-2 at ρg = 0.01) | flat plate [read] |
| `flat_plate_column_check.jl::_fit_flat_plate_columns!` | **replace** with the lightest passing plan group, floored by `floors` (and by the current size when uniform sizing is on or no punching demands are stored) | flat plate [read] |
| `member_iteration.jl::harmonize_uniform_column_sizes!` | max within story/building | all, when on [read] |
| `size_columns.jl::size_columns!` (`_size_columns_impl!` steel / RC / PixelFrame) | **replace** (fresh MIP/NLP), masked by `_frame_floor_mask` | beam frames [read] |
| `check_settle.jl::_install_state!` / `_resize_failures!` | replace with a checked state | beam frames [read] |
| `check_settle.jl::_restore_passing_columns!` | restore the kept section | story shell [read] |
| `interactive_checks.jl::_raise_frame_floors!`, `pipeline_spec.jl::_floor_overstressed_frame_columns!` | write **floors** (not sections) | beam frames, RC [read] |

### beam.section

| writer | rule |
|---|---|
| `size_beams.jl::size_beams!` → `_size_beams_impl!` per framing level (`_beam_sizing_passes`) | replace, masked by `section_floor` (`_apply_section_floor`), `_frame_floor_mask`, and `member_group_overrides` [read] |
| `size_beams_story_shell.jl::_story_shell_passes!`, `_trim_story_shell!` | replace / floor / exact put-back [read] |
| `check_settle.jl::_check_settle!`, `_reconcile_shell_frame!` | install checked state; resize failing groups only [read] |
| `raise_head_face_ribs!`, `conform_rib_lines!`, `grow_building_solid_heads!` | grow (waffle/rib) [read call sites only] |
| `_raise_frame_floors!` | floors [read] |

### Floors (persisting state)

| floor | stored in | lifetime | relaxes? |
|---|---|---|---|
| row-F / overstressed column floor | `struc.frame_section_floors` | rest of the design | No [read] |
| story-shell `section_floor` | local `floor` in `_size_with_story_shell!` / L-SP | one member-stage call | No within the call; a new member-stage call starts free [read] |
| flat-plate reanalysis floor | local `floors` in `_design_flat_plate_members!` | one member-stage call | No [read] |

---

## 5. Fast-tier inventory (F.1)

### 5.1 Demand sources

| element | demand source | fidelity | where chosen | embedded in designer? |
|---|---|---|---|---|
| beam-frame columns (RC, steel) | `member_group_demands` on the Asap frame: full load plus `_pattern_demand_cases`, 200 stations/element; RC also `ColumnCaseRow` per pattern case | frame | `size_columns.jl::_size_columns_impl!` [read] | Yes. `_size_columns_impl!` applies gravity (`_add_gravity_loads!`) and reads the model [read] |
| flat-plate columns | slab loop: tributary Pu (single-floor) + slab-analysis joint moments; member stage: frame `Pu` + `flat_plate_joint_demands` + stored punching `Vu/Mub` | ddm/efm/fea (slab area) + frame | `flat_plate_column_check.jl::flat_plate_column_checks` [read] | Yes |
| steel/RC beams (no shell) | `member_group_demands` (frame, tributary area loads applied to beams) envelope; T-beam flange envelope | frame | `size_beams.jl::_beam_group_demands` [read] | Yes |
| beams on shell stories | `max(frame, shell)` per group from `solve_story_shell!` (`ShellBeamDemand`) + service spans | shell_story | `size_beams_story_shell.jl::_gather_shell_demands!` [read] | Yes, inside the pass loop |
| row-F check | `_member_demand_rows`, per combination × case × element | frame (+ second order) | `interactive_checks.jl::_check_frame_member_strength` [read] | No, separate check |

### 5.2 Pure checks (geometry, size, demand → pass/fail)

- RC column: `SS/members/codes/aci/columns/checker.jl::is_feasible` (P-M
  diagram, ACI slenderness, biaxial), `floor_transmission.jl::joint_concrete_strength`
  (§10.12). Pure given a precomputed `ACIColumnCapacityCache` [read].
- RC beam: `checker/checker_strength.jl::is_feasible` (§10.2 flexure, §11.2
  Vc, §11.4.7.9 Vs,max, §10.3.5 εt ≥ 0.004, §10.5.1 As,min, §11.5.3.1 torsion,
  §9.5.2 shell deflection), and the T-beam `t_checker.jl` [read].
- Steel: `aisc/checker/steel_feasibility.jl::is_feasible`. Pure given
  `AISCCapacityCache`; lazy per-Lb memo in `cache.jl::_get_ϕMnx_cached!` [read].
- Composite: `composite_feasibility.jl::is_feasible`. Needs slab/stud context
  and shell spans, so it is not pure in the slab variables [read].
- Punching at a trial column size: `check_punching_for_column` on stored
  demands, pure in (c1, c2, stored Vu/Mub) [read docstring in
  `_fit_flat_plate_columns!`].

### 5.3 Cost drivers [read unless marked]

1. **Full frame re-assembly and solve after every section change.**
   `_reanalyze_after_section_change!` = `Asap.update!` (full K) + solve +
   `_refresh_pattern_solve_cache!` (all pattern cases). This runs once per
   story-shell pass, per trim, per `_resize_failures!`/`_resize_rejected!`
   step, and per cycle state in `_check_settle!` (each `_install_state!` then
   group reports at resolution 200). `update_analysis!(:stiffness)` runs twice
   per L-BC pass.
2. **Story-shell solves.** One `solve_story_shell!` per level per pass
   (≤10 passes × ≤3 rounds, + trim, + ≤4 reconcile attempts), with an iterative
   cracked service solve when on. The mesh is cached per `_size_with_story_shell!`
   call (`shells` dict), but L-WM re-enters the member stage and re-meshes
   [inferred: `shells` is local].
3. **RC column P-M precompute.** The SY `size_columns!` path passes no cache.
   Each `size_columns!` therefore builds `generate_PM_diagram` for every catalog
   section (and y-axis diagrams for non-square sections), threaded. With a row-F
   floor, the catalog is rebuilt (`rc_column_catalog`), so the memo key
   (`objectid(catalog)`) misses. The flat-plate fit builds its caches once per
   `_fit_flat_plate_columns!` call (one round of L-FP2).
4. **MIP solves.** One JuMP model per `size_columns!`/`size_beams!` call per
   framing level. With `n_max_sections = 0` the problem is separable (each group
   is the min-objective feasible section), but HiGHS is still called
   [read `model.jl`; the separability is inferred]. The feasibility screen is
   groups × catalog `is_feasible` calls. RC column demand sets multiply this
   by 2·(1 + n_pattern).
5. **Demand extraction.** `member_group_demands`: 200 stations × elements × (1 +
   n_pattern) cases, every pass and in every group report.

### 5.4 What a fast tier needs

- A demand provider interface that returns `MemberDemand` / `RCColumnDemandSet`
  per group from tributary loads or a coarse frame, with no `struc.asap_model`
  side effects. Today `_size_columns_impl!` mutates loads
  (`_add_gravity_loads!`) and reads the model directly [read].
- Persistent capacity caches keyed by (catalog, material, objective).
  `optimize_discrete` already accepts `cache=`, but SY never passes one [read].
- A closed-form pick for `n_max_sections = 0`: argmin objective over feasible
  sections, no JuMP [inferred].
- The B1/Cm inputs and slenderness geometry (Lu, k) are available from geometry
  alone. Moments for RC slenderness need M1/M2. A tributary tier would have to
  assume single curvature (`M1 = −M2`), as `columns.jl` positional RC API does [read].
- Separation blockers: frame floors, harmonize and fire coating write into the
  model inside the loops; story-shell demands are only produced inside
  `size_beams_with_story_shell!` [read].

---

## 6. Size-impact and speed findings (ranked)

**Size impact**

1. **S1 — Row-F and overstressed-column floors never relax (HIGH).**
   `_raise_frame_floors!` walks up from the heaviest current objective.
   `_floor_overstressed_frame_columns!` floors at the current failing section.
   `_frame_floor_mask` keeps only the floor and strictly heavier sections. All
   persist across L-WM rounds. Floors set under an early wall/beam state stay
   after walls thicken. The overstressed check uses the envelope demand, which
   can flag columns that pass every concurrent row [read; consequence inferred].
   The relaxation fix exists on `row-f-nlp` but is unmerged.
2. **S2 — Story-shell beam ratchet (MED-HIGH).** Grow-only after 2 free passes
   (L-SP) and between rounds (L-SR, non-checkable). Trim only once, in round 1.
   Checkable discrete options avoid rounds 2–3 through L-RSF, which keeps passing
   groups (sticky) rather than re-trimming [read].
3. **S3 — Uniform harmonize by independent max(c1), max(c2) (HIGH when on).**
   It also turns off flat-plate column shrink entirely (`shrink =
   uniform_column_sizing === :off`) [read].
4. **S4 — RC discrete objectives ignore reinforcement (MED).** Gross `b·h`
   only, for carbon and cost too. Ties are broken arbitrarily by the MIP [read].
5. **S5 — Group envelope still in RC demand sets, and envelope geometry (MED).**
   Max P × max M across members and cases, longest L, max K. Case rows only add
   constraints [read].
6. **S6 — Flat-plate reanalysis floors (LOW-MED).** A size a slab redesign
   needed at an intermediate slab state floors the fit for the rest of the
   call [inferred from `_raise_column_floors!`].
7. **S7 — Steel Cm = 0.6 for compressed members (SAFETY, unconservative, not
   size).** For beam-columns with transverse load or single curvature, AISC App. 8
   requires a higher Cm (single curvature M1/M2 = −1 gives 1.0). B2 is not
   applied either [read]. This needs an engineer's sign-off.

**Speed**

1. **P1 — Full re-assembly per section change** (§5.3.1). It runs in every
   check-settle state, reconcile attempt and story-shell pass.
2. **P2 — Story-shell solve count**: up to (10 + trim) passes × levels in round 1,
   plus ≤4 reconcile solves, plus the whole stage again per L-WM round.
3. **P3 — RC P-M diagrams regenerated per `size_columns!` call** (no shared
   cache; memo misses when floors rebuild the catalog).
4. **P4 — JuMP/HiGHS for separable assignments** when `n_max_sections = 0`.
5. **P5 — Demand-set blow-up for RC columns**: 2·(1 + n_pattern) rows per group,
   each a P-M check per catalog section.

---

## 7. Open questions

1. Should `row-f-nlp` (items 1, 2, 3, 7, objectives) be merged? The task
   brief described its features as landed, but `main` does not have them.
2. Steel `Cm` default `M1 = 0` → 0.6: confirm the intended conservative
   default (AISC 360-16 App. 8 Eq. A-8-4; with transverse loading, App. 8.2.1(a)
   permits Cm = 1.0). Safety-relevant; needs sign-off.
3. `_floor_overstressed_frame_columns!` checks the envelope
   (`frame_column_demand(envs[i])`), but sizing checks envelope + case rows. Is
   flooring on the envelope intended?
4. `_lightest_passing_group` assumes monotonic pass/fail over plan-area-sorted
   groups. Punching depends on the perimeter and aspect ratio, so a lighter
   passing group can be skipped (conservative). Is that acceptable?
5. `_fit_flat_plate_columns!` reuses the stored `Vu` at a smaller trial
   column. Vu at d/2 grows slightly as the column shrinks. The stale-slab
   loop re-checks at the installed size afterward. Confirm that this closure
   is the intended safety net.
6. Harmonized RC frame columns get `_assign_flat_plate_column_section!` bars
   (same bars, or minimum 1 %) without a P-M re-check against frame demands
   in the beam-frame path [read call; consequence inferred]. Is a re-check needed?
7. Should `_stack_flat_plate_columns!` / `_grow_flat_plate_columns!` (dead
   code) be deleted?
