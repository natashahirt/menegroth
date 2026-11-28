# Walls, lateral system, foundations: re-audit 2026-11-18

Area: `walls_lateral_foundations`. Baselines:
[`../raw/walls-lateral-foundations.md`](../raw/walls-lateral-foundations.md) and
[`../raw/vertical-floor-interaction.md`](../raw/vertical-floor-interaction.md)
(both 2026-11-11). Working tree of `main` at `7236704d` plus uncommitted and
untracked files, read on 2026-11-18. Paths: `SS/` = `StructuralSizer/src/`,
`SY/` = `StructuralSynthesizer/src/`. Map fragment:
[`walls_lateral_foundations.map.yaml`](walls_lateral_foundations.map.yaml).

## Preface: branch state (read this first)

The Phase 0 foundation and seismic-weight work recorded in memory on 11-12
(cladding dead load, per-combination foundation actions, spread footings on
ASCE 7-22 §2.3/§2.4, Bowles strip statics for rigid mats, the framed-member
term in Kr, Row F floor relaxation) was committed on branch **`row-f-nlp`**
(worktree `/tmp/menegroth-rowf`, HEAD `9c951d8c`, 22 commits ahead of the
merge base `2f09b8f3`). **None of it is on `main`.** [read: `git log
main..row-f-nlp`; `git grep` on both refs]

- `main` has 2 commits `row-f-nlp` lacks: `581774cb` (special walls Ve,
  boundary bars, coupling beams) and `2bbcdf43` (SDC D–F gravity frames).
  [read]
- `main`'s working tree also carries a large uncommitted refactor:
  `SY/analyze/foundations/utils.jl` (−1513 lines) split into untracked
  `supports.jl`, `demands.jl`, `grouping.jl`, `strategy.jl`, `size_*.jl`,
  `wall_groups.jl`, `initialize.jl`, `reporting.jl`; plus uncommitted
  `SS/foundations/codes/aci/wall_plan.jl` (untracked), a rewritten
  `mat_footing.jl` (Kr gate), `wall_strip_footing.jl`, `spread_footing.jl`
  (Chapter 12 development). [read: `git status`, `git diff --stat`]
- Merging `row-f-nlp` will conflict with that split (the branch edits the
  monolithic `utils.jl`). [inferred]

The memory checkpoint "Foundation lateral combinations and mat strip statics
are blocked" (`chec-2dea3888`) was superseded on the branch by
`chec-c02a67bc` (spread combos) and `chec-354fc41f` (Bowles statics), but on
`main` the blocked state is still the live state.

### Phase 0 status table

| Item | `main` working tree | `row-f-nlp` |
|---|---|---|
| Cladding (`wall_SDL`) on perimeter beams, D, service, W, Px | **Absent.** `wall_SDL` has no consumer in `SY/` outside the API deserializer. [read: grep] | `SY/analyze/asap/asap/cladding.jl` (factored `:cladding` line loads; service copy in `foundations/utils.jl:144`). [read] |
| Lateral reactions into foundations | **Absent.** `initialize_supports!` reads `node.reaction` of the last mutating gravity solve; `_service_reactions` adds one unfactored D+L solve. Wall-stage solves return displacements only. [read] | `SY/analyze/lateral/foundation_reactions.jl::foundation_lateral_cases` stores D, L, roof, each wind, each QE support reaction; `foundation_actions_at` combines. [read] |
| Spread footings on ASCE 7-22 §2.3/§2.4 combos | **Absent.** `SS/.../spread_footing.jl::design_footing(::SpreadFooting, demand, soil)` takes one `FoundationDemand`. [read] | `_spread_plan_for_actions` checks every service and strength action. Strip/mat still one demand (largest-moment compressive strength combo). [read] |
| Rigid-mat strip statics (Bowles §9-2/§10-6) | **Absent.** `SS/.../mat_footing.jl::_rigid_mat_strip_moments` still uses wL²/10, /11, /12 and wL²/2 for one span, face assignment unchanged. [read] | Present: `_rigid_mat_strip_moments(qu, length_along, width_across, stations, loads)`. [read] |
| Rigid-mat gate (ACI 336.2R Eq. 5-1, §6.1.2 Step 3) | **Present (uncommitted).** `mat_footing.jl::_rigid_mat_inapplicable`: Kr ≥ 0.5 on both widths, spans < 1.75/λ, loads and adjacent spans within 20%; else Winkler or throw. [read] | Present. |
| Kr framed-member (superstructure) term, Eq. 5-2 | **Absent.** `SS/.../wall_plan.jl::wall_footing_kr` = footing `h³/12` + Σ walls `t_w h_w³/12 / B`; no beam/column term. [read] ACI 336.2R notation defines `I_B` as the moment of inertia per unit width of the superstructure (corpus `aci-336-combined-footings-mats`, PDF p. 2). | `foundation_stiffness.jl::wall_footing_kr(...; framed_I)`; SY passes `_mat_framed_inertia` for the strategy mat only (`utils.jl:534`). Grade-wall mat passes none. [read] |
| Grade walls reach wall-strip / mat design | **Yes.** `SY/analyze/foundations/wall_groups.jl::design_grade_wall_foundations` sends open groups to `design_footing(::StripFooting, legs, soil)` and closed cells (with enclosed columns) to `design_footing(::MatFoundation, …; walls=legs)`. Called first inside `size_foundations!`. [read] | Same file, same call. |
| Grade walls get lateral demand | **No.** Legs carry only vertical `nd.reaction[3]` and service `R_s[gid[3]]` per base node; no base moment, no shear, no per-combination action. [read: `collect_grade_wall_groups`] | No: `foundation_actions_at` is wired to column supports only. [read: grep] |
| Wall strip from unfactored area, full-contact pressure | **Yes.** `_size_wall_plan` sizes on service resultant with `q ∈ [0, qa]`; `_design_wall_rigid` refuses factored partial contact (or Winkler for a straight wall). [read] | Same design; memory says the branch copy did not load (`_Aabb` missing). |

---

## 1. Changes since 2026-11-11

Walls and lateral:

- **Special walls, Ve, boundary bars, coupling beams landed** (`581774cb`).
  `_analyze_lateral_walls!` now runs, for piers on rows A1/B4, a 12-pass
  fixed point between `design_special_wall_shear!` (Ωv·ωv Ve, ACI 318-19
  §18.10.3) and `design_boundary_end_bars` (§18.10.2.4, §18.10.6), and throws
  if it does not settle. [read: `ordinary_wall_stage.jl:420-431`]
- **Coupling beams are checked, not sized.** Horizontal segments between
  piers of a special row go to `wall_opening_checks.jl::check_coupling_beam`
  (route by ℓn/h and Vu: §18.6, §18.6.3–5, or diagonal §18.10.7.4). `bw` is
  the wall thickness, `h` the segment height; neither is a variable. Bars and
  hoops are designed for the largest action. [read]
- **Gravity frames in SDC D–F** (`2bbcdf43`): `gravity_induced.jl::
  gravity_induced_checks` records §18.14.3.2/§18.14.3.3 detailing. No sizing
  lever. [read]
- **Moop now pairs per combination.** `_governing_slab_basis` returns
  `(qD, qL, faces)` and `wall_ordinary_check.jl::_action_slab_moment` scales
  each face moment by that combination's D and L factors, so 0.9D no longer
  gets the 1.2D+1.6L moment. Still flat plate only, still max over slabs at
  the pier's top and bottom joints, not split. [read]
- **Seismic weight W** includes wall shells, frame `GravityLoad`
  self-weight, half to each end (`elf_story_cases.jl::_elf_weight_items`);
  the 11-11 raw report's "W is cell only" was already corrected in the README.
  So a thicker wall raises W and V. The thickness proxy ignores this. [read
  header; proxy behaviour inferred]
- **Wind** is now its own StructuralSizer module, `SS/loads/wind/`
  (Eq. 27.3-1 pressures, Fig. 27.3-8 Cases 1–4, §27.1.5 minimum, §26.11 gust
  for Eq. 27.3-4). `SY/analyze/lateral/wind_story_cases.jl::wind_story_analysis`
  places the resultants on masters. qz/qh are inputs (`OrdinaryWallInputs`).
  [read]
- **Diaphragms**: `flexible_diaphragm.jl` and `semirigid_diaphragm.jl`
  (untracked) give masterless floors their own load placement and drift
  reading; on those floors the stage stays first-order and multiplies seismic
  member forces by 1/(1−θ). [read: docstring `design_ordinary_walls!`]
- **Thickness jump: unchanged in the respects that matter.**
  `_group_needs_thickness` still returns true for every group when any drift
  check fails; `propose_wall_thickness` still uses `t0 · _drift_scale(drift)`
  with `_drift_scale` = max over all stories/directions/torsion signs; the
  proxy still treats drift ∝ t0/t. [read] Default grouping `:pier`, budget
  `_wall_thickness_pass_cap + 1` = 3 (`:all`) or 7. [read]
- **`story_drift_sensitivity` is still unused** by `SY/`. Grep finds no
  caller of `story_drift_sensitivity`, `ReducedDiaphragmEvaluator`,
  `evaluate_lateral` or `WallLayoutNLPProblem` in `SY/src`. The function's own
  comment says it differentiates origin-referenced drift and is "NOT the
  optimizer's gradient source". [read]
- **Row F frame floors** still only move up (`interactive_checks.jl::
  _raise_frame_floors!`); the relaxation (`09beee10`) is on `row-f-nlp`
  only. [read]

Foundations:

- **New on `main` (uncommitted):** `wall_plan.jl` (L/T wall footing plan,
  `wall_footing_kr`, `footing_lambda` Eq. 5-3), `wall_groups.jl` (grade-wall
  grouping into strip/mat), the rigid-mat applicability gate, wall-strip
  Winkler fallback for straight walls, ACI 318-11 Chapter 12 development
  (Eq. 12-1, hooks §12.5.2) in spread and mat. [read]
- **Spread footing kern gate.** `design_footing(::SpreadFooting)` grows the
  square until q_min ≥ 0 and service q_max ≤ qa, then refuses partial
  contact. Still square; still one demand. [read]
- **Unchanged:** grouping envelope (`grouping.jl`), strategy coverage
  heuristic, strip `h ≤ 0.5B`, strip "worse axis" choice, Winkler linear
  sweep. [read]

Items from `vertical-floor-interaction.md` §10–§12:

| Item | Status on `main` |
|---|---|
| §10 HIGH: wall jump does not restale flat-plate slabs | **Open.** `graph_builder.jl::_slab_checked_at_installed_columns` keys on column c1, c2, shape only. [read] |
| §10 HIGH: Moop = max single-face moment paired with 0.9D | **Partly fixed.** Per-combination D/L scaling via `slab_basis`. Max over slabs, no top/bottom split, flat plate only remain. [read] |
| §10 HIGH: B.6 20% gate throws instead of resizing | **Open.** `_refuse_building_frame_gravity!`. [read] |
| §10 MED: flat-plate wall N tributary vs shell raise for beam floors | **Open.** `_gravity_raised_to_shell` only for story-shell levels. [read] |
| §10 MED: sway/nonsway flips on "any wall meets slab" | **Partly.** `column_bracing.jl` now uses `story_properties` Q when present, else walls ⇒ nonsway. [read] |
| §11.1 Moop = 0 for non-flat-plate floors | **Open.** `_slab_moment_into_wall` filters `FlatPlatePanelResult`. [read] |
| §11.4 `:flat_slab` escapes row-F refusal | **Open.** `_refuse_flat_plate` tests `:flat_plate` only. [read] |
| §11.7 diaphragm user-declared | **Open.** `diaphragm_construction` is a user input; `deck_floor_diaphragm` has no `SY/src` caller. [read] |
| §11.3 deck bearing never run | **Open.** No `bearing_length` caller in `SY/src`. [read] |
| §12 wire `story_drift_sensitivity` / layout NLP | **Not done.** [read] |
| §12 restale slabs on wall-t jump | **Not done.** [read] |

---

## 2. Flow

Pipeline (`SY/workflow/pipeline_spec.jl::build_pipeline`): slabs → members →
**walls (`_walls_with_member_recheck!`, `needs_sync=false`)** → foundations
(`_size_foundations!`, `needs_sync=false`). No outer loop. [read]

### 2a. Walls stage

1. `_walls_with_member_recheck!` (≤ 4 rounds): call `design_ordinary_walls!`;
   then `_floor_overstressed_frame_columns!` floors any RC frame column that
   fails P–M on the wall solution at its current section; if thickness,
   frame floors, or an overstressed column changed, re-run the whole member
   stage (`_size_beams_columns!` or `_design_flat_plate_members!`) and
   `sync_asap!` (non-flat only); stop when member sections are identical.
   [read]
2. `design_ordinary_walls!` = `settle!` over passes. Each pass calls
   `_analyze_lateral_walls!` (or `_analyze_gravity_walls!` when
   `params.lateral === nothing`), then `propose_wall_thicknesses`, then
   `apply_wall_thickness!` → `update_analysis!(:geometry)` = full `to_asap!`
   rebuild + `_restore_sized_frame_state!` (ends in `sync_asap!`). The last
   pass does not apply a jump. [read]
3. One `_analyze_lateral_walls!` pass, in order [read]:
   - Validate `wall_inputs`; Table 12.2-1 rows per direction
     (`concrete_shear_wall_system`); `prepare_lateral_model!`; diaphragm
     layout (`semirigid_sfrs!` / `flexible_diaphragm_layout!` / rigid).
   - `solve_gravity_basic_cases` (D, L, roof; shell model, 3 RHS) with cut
     equilibrium checks.
   - `wind_story_analysis` (Ch. 27 cases, one batch solve).
   - `elf_story_analysis` (ELF: 2 purposes × 2 directions × 3 torsion = 12
     RHS, one batch). `seismic_effect_cases` (one-direction or 100/30, 16).
   - `require_seismic_wall_demand_provisions` (θ ≤ θmax, cracked stiffness,
     ρ on Eh, orthogonal, torsion, P-Δ statements); `system_checks`.
   - `_story_drift_with_pdelta` (ASCE 7-22 §12.8.6, §12.8.7 1/(1−θ)).
   - `_build_second_order`: one factorization of K − K_G per distinct
     factored-gravity key (≈ 4–6 from `_stage_gravity_keys`), batch of
     3 + nwind + nQE RHS each. Skipped on masterless floors.
   - `_wall_dead_load_shares` → `_refuse_building_frame_gravity!` (B.6/B.4
     20% project limit).
   - Per solid pier: pier-cut actions per combination
     (`_pier_action_batches`), `_select_pier_steel!` →
     `select_ordinary_wall_reinforcement!` (ρt then ρl from the floor).
   - Row F: `_enforce_interactive_wall_shear!` (ρt bumps to 0.75 V),
     `_check_interactive_frames!` (frames without shells at 25% V; sets
     `frame_section_floors`).
   - Special rows: boundary route, then the 12-pass Ve ⇄ end-bar fixed point.
   - Record checks per action (`_each_second_order` → `check_ordinary_wall`
     + §6.2.5.3 1.4× limit), special shear records,
     `_design_pierced_segments!` (vertical segments, spandrels, coupling
     beams), `_record_joined_joints!`, story shear, frame members, final
     boundary decisions, `gravity_induced_checks`.
   - Build `WallThicknessTrial` per solid pier (frozen actions, Moop, basis).
4. `propose_wall_thicknesses`: for each group that needs thickness, the
   thinnest inch ≥ t0·max(drift ratio, interactive ratio, shear-cap ratio,
   geometric gates) that `wall_thickness_passes` accepts (re-picks ρ and
   re-runs `check_ordinary_wall` on t-scaled axial); then
   `_raise_boundary_thickness!` per pier for the §18.10.6.4 web shortfall.
   [read]

Writes: `wall.thickness`, `wall.ρl`, `wall.ρt`, `params.wall_thickness`,
`struc.frame_section_floors`, `struc.ordinary_wall_result`,
`struc.diaphragm_layout`, `struc.site.sdc`, `stage_diagnostics[:walls]`,
`[:wall_members]`. [read]

### 2b. Foundations stage

`_size_foundations!` → `initialize_supports!` (forces/moments = last
mutating solve's node reactions; c1/c2 from the column or 18 in default) →
`size_foundations!` [read]:

1. `support_demands`: one `FoundationDemand` per support: Pu, Mux, Muy, Vux,
   Vuy from those reactions; Ps from `_service_reactions` (unfactored D+L
   reusing the factorization). Gravity only. [read]
2. `design_grade_wall_foundations` **first**: `collect_grade_wall_groups`
   reads pier base nodes at grade, classifies wall pieces into closed cells
   (mat with enclosed columns) or open runs (wall strip). Column supports on
   or inside those groups are skipped later. [read]
3. Strategy: explicit groupings, else `_resolve_strategy` (coverage
   Σ Ps/qa ÷ bounding box: > 0.50 mat, > 0.30 strip, else spread). [read]
4. `:mat` → one `MatFoundation` over remaining supports via `_size_foundation!`
   → `_size_fnd_aci!`; `:strip` → orthogonal column-line strips or
   `_auto_merge_to_strips!`; `:spread` → `group_foundations_by_reaction!`
   (±15%) → `size_foundations_grouped!` (component-wise max demand per
   group). [read]
5. SS design: spread (`spread_footing.jl::design_footing`), column strip
   (`strip_footing.jl::design_footing`), mat (`mat_footing.jl::design_footing`
   → `_design_mat_rigid` → `_rigid_mat_inapplicable` → maybe
   `_design_mat_winkler_fea`), wall strip (`wall_strip_footing.jl::
   design_footing(::StripFooting, legs, soil)` → `_size_wall_plan` → Kr at
   `opts.min_depth` → rigid or straight-wall Winkler). [read]

---

## 3. Loops

| id | anchor | iterates | budget | growth | converges when | writes | ratchet |
|---|---|---|---|---|---|---|---|
| W1 thickness jump | `SY/analyze/lateral/ordinary_wall_stage.jl::design_ordinary_walls!` | wall.t per group | 3 (`:all`) / 7 | grow-only | no target grows > 0.1 mm | wall.t, ρ reset 0.0025, model rebuild | **yes** [read] |
| W2 walls ⇄ members | `SY/workflow/pipeline_spec.jl::_walls_with_member_recheck!` | W1 + member stage | 4 rounds | grow-only on walls and floors | t, floors same and no overstressed column, or member sections identical | member sections, frame floors | **yes** (walls never thin after member change) [read] |
| W3 Ve ⇄ end bars | `ordinary_wall_stage.jl::_analyze_lateral_walls!` (`for _pass in 1:12`) | special ρt/ρl, end bars | 12, throws | free+guard | `_same_end_bars` | wall ρ, end_bars | no (rebuilt each analysis) [read] |
| W4 row F wall shear | `interactive_checks.jl::_enforce_interactive_wall_shear!` | ρt of lowest-ρt wall | until stall | grow-only | Σφ Vn ≥ 0.75 V | wall.ρt, ρl re-raise | within the pass only (ρ re-picked next pass) [read] |
| W5 row F frame floors | `interactive_checks.jl::_raise_frame_floors!`; `pipeline_spec.jl::_floor_overstressed_frame_columns!` | catalog floor per group | catalog length | grow-only | all group members pass | `frame_section_floors` | **yes**, kept for the run (reset only in `prepare!`) [read] |
| W6 ρ grid walk | `wall_ordinary_check.jl::select_ordinary_wall_reinforcement!` | ρt, ρl on 0.0005 grid | to 0.02 | free (restarts from floor) | first passing grid point | wall.ρ | no [read] |
| W7 proxy search | `wall_thickness_jump.jl::_first_passing_thickness` | candidate inch | to catalog limit, soft +12 in to 72 in | grow-only | proxy passes | proposed t | n/a [read] |
| W8 OOP service deflection | `SS/walls/out_of_plane.jl::oop_service_deflection_si` | Δs fixed point | 100 | free | rel tol 1e-10 | none | no [read 11-11; unchanged file region inferred] |
| F1 spread plan/kern | `SS/foundations/codes/aci/spread_footing.jl::design_footing` | B = L | 80 × 3 in | grow-only | kern and q_max ≤ qa | fdn.B | no [read] |
| F2 spread development | same | bar size → hook → plan | 40 | grow-only | develops | fdn.B, bars | no [read] |
| F3 strip B, h | `SS/.../strip_footing.jl::design_footing` | B outer, h inner | 30 × 80 | grow-only | checks + h ≤ 0.5B | fdn.B, fdn.h | no [read 11-11; diff is 4 lines] |
| F4 rigid mat | `SS/.../mat_footing.jl::_design_mat_rigid` | overhang (40), h (60) | 40/60 | grow-only | punching, flexure, dowels, development | fdn.h, overhang | no [read] |
| F5 Winkler mat | `SS/.../mat_winkler/design.jl::_design_mat_winkler_fea` | h linear sweep; active set ≤ 20 | 60 − k_h | grow-only | checks pass | fdn.h | no [read] |
| F6 wall plan | `SS/.../wall_plan.jl::_size_wall_plan` | B widen or free-end extend | 80 | grow-only | 0 ≤ q ≤ qa | fdn.B, ends | no [read] |
| F7 wall-strip h | `wall_strip_footing.jl::_design_wall_rigid` / `_design_wall_winkler` | h | 60 | grow-only | shear, flexure, dowels (Winkler: + bearing) | fdn.h | no [read] |
| F8 reaction grouping | `SY/analyze/foundations/grouping.jl::group_foundations_by_reaction!` | membership | one pass | rep = max | — | group_id | rep only grows (chaining) [read] |

---

## 4. Writers

| Variable | Writer | Rule |
|---|---|---|
| `wall.t` | `SY/core/initialize.jl` / `prepare!` from `params.wall_thickness` | replace (seed) [read 11-11] |
| `wall.t` | `wall_thickness_jump.jl::apply_wall_thickness!` (both methods) | replace with target only when it grows [read] |
| `wall.t` target | `propose_wall_thicknesses` | group max over need; **drift need applied to every group** [read] |
| `wall.t` target | `_raise_boundary_thickness!` | max(target, next inch over §18.10.6.4 shortfall), per pier [read] |
| `wall.ρl`, `wall.ρt` | `select_ordinary_wall_reinforcement!` | replace from §11.6.2 / Eq. 11.5.4.3 floor [read] |
| `wall.ρl`, `wall.ρt` | `apply_wall_thickness!` | reset 0.0025 on grown walls [read] |
| `wall.ρt` | `_bump_rho_t!` via `_enforce_interactive_wall_shear!` | raise one grid step on lowest-ρt wall [read] |
| `wall.ρl` | `_reraise_vertical_ratio!` | re-pick after ρt raise [read] |
| `wall.ρ` | `_raise_for_special_shear!` | raise for Ve [read] |
| `wall.ρ` | `_copy_segment_reinforcement!` | copy owner's ρ to other walls of a segment [read] |
| `wall.ρ` | `wall_thickness_passes` | temporary, restored in `finally` [read] |
| end bars | `design_boundary_end_bars` | replace each W3 pass [read] |
| `frame_section_floors[gid]` | `_raise_frame_floors!`, `_floor_overstressed_frame_columns!` | max by objective [read] |
| `params.wall_thickness` | `apply_wall_thickness!` | replace when walls share one thickness [read] |
| `struc.supports` | `initialize_supports!` | replace [read] |
| `fdn.*` group demand | `size_foundations_grouped!` | component-wise max of Pu, Ps, M, V, c1, c2 (c ≥ 18 in) [read] |
| `fdn.B, fdn.h` | each `design_footing` | first passing grid point [read] |
| foundation type | `_resolve_strategy`, `_auto_merge_to_strips!`, `design_grade_wall_foundations` | replace [read] |

---

## 5. Fast-tier inventory (F.1)

### Walls

- **Where the analysis is chosen:** inside `_analyze_lateral_walls!` (and
  `_analyze_gravity_walls!`). The designer builds and solves every analysis
  itself: gravity basic cases, wind, ELF, K_G sets, row-F frames. Analysis is
  embedded in the designer. [read]
- **Pure checks:** `SS/walls/checker.jl::check_wall_inplane_shear`,
  `check_wall_min_reinforcement`, `SS/walls/bearing.jl::
  check_wall_bearing_empirical`, `SS/walls/flexure.jl`,
  `SS/walls/out_of_plane.jl::check_wall_out_of_plane_*`,
  `SS/walls/special_boundary.jl`, `SS/walls/coupling_beams.jl` are pure in
  (geometry, t, ρ, material, actions). `SY/.../wall_ordinary_check.jl::
  check_ordinary_wall` is pure in (wall, actions, Moop, basis) but takes the
  SY `Wall` type; `select_ordinary_wall_reinforcement!` mutates `wall.ρ`.
  [read]
- **Cheapest credible demand source that exists:** `SS/walls/lateral/`
  `ReducedDiaphragmEvaluator` + `evaluate_lateral` (3 DOF per story,
  `K = Σ k_i b_i b_iᵀ`, analytic `k_i` from `wall_section.jl`, accidental
  eccentricity, torsion amplification) with `story_drift_sensitivity` and
  `eigenstructure_stability`. ELF story forces are closed form
  (`SS/loads/seismic.jl`), wind resultants closed form (`SS/loads/wind/`).
  The SY bridge exists (`to_wall_line`, `story_plate_geometry`,
  `story_center_of_mass`, `wall_lateral_stiffness(::Wall)`), but no sizing
  caller. [read]
- **What a fast source would need:** per-pier N/V/M per combination (the
  reduced model gives story shear per wall line, not N or M along the
  height; gravity N would come from tributary); Moop from the slab; a
  P-Δ story stiffness term (θ from Px/Vx is available closed form); δu at
  the top for the §18.10.6.2 route. [inferred]
- **Blockers:** (a) pier actions are cuts of the unified shell solution
  (`pier_wall_action`), including frame interaction, openings and joined
  corners, which the reduced model does not have; (b) row F needs frames
  solved without shells; (c) `_require_gravity_cut_equilibrium` and
  `_build_second_order` assume the shell model; (d) pierced walls and
  coupling beams need segment forces from the shell mesh; (e) the
  reduced evaluator has no opening, frame or flexible-floor model. [read for
  where each is computed; feasibility inferred]

### Foundations

- **Where the analysis is chosen:** demand extraction in SY
  (`initialize_supports!`, `support_demands`, `collect_grade_wall_groups`)
  reads the full building model; method choice (rigid / Winkler / Shukla)
  inside SS `design_footing(::MatFoundation)` and wall strip. [read]
- **Pure checks:** every SS `design_footing` is a pure function of
  (`FoundationDemand` or `WallLineDemand`, positions, soil, opts). Spread,
  column strip, rigid mat and rigid wall strip are rigid statics already;
  only Winkler mats and the straight-wall Winkler fallback solve. [read]
- **Cheapest credible demand source:** column axial from the member stage's
  own demands or tributary area, plus a closed-form overturning from the
  reduced lateral model per wall line. Today no such source is wired; the
  full-model reactions are the only one. [inferred]
- **What a fast source would need:** a per-combination action type (exists
  only on `row-f-nlp`: `SS FootingAction`, `foundation_combination_actions`);
  wall-line base moments for grade walls; framed-member stiffness for Kr.
  [read on branch; need inferred]
- **Blockers:** `FoundationDemand` holds one (P, M) set on `main`;
  `WallLineDemand` holds only vertical samples. [read]

### Where the expensive shell-model solves happen (per wall pass)

1. `update_analysis!(:geometry)` → `to_asap!` rebuild + `sync_asap!` (one
   factorization + gravity solve). [read]
2. `solve_gravity_basic_cases`: 3 RHS on the reduced system. [read]
3. `wind_story_analysis`: one batch. [read]
4. `elf_story_analysis`: 12 RHS. [read]
5. `_build_second_order`: **one new factorization per gravity key** (≈ 4–6),
   each with 3 + nwind + nQE RHS (nQE up to 16 with 100/30). Dominant. [read]
6. Row F `_check_interactive_frames!`: frame-only solves. [read]
7. `_build_first_order` for joined corners on masterless floors. [read]

Then per W2 round, the whole member stage; foundations add one service
solve (`_service_reactions`) and, for Winkler mats, an active-set FE solve
per inch. [read]

---

## 6. Size-impact and speed findings (ranked)

Size:

1. **Foundations see gravity only (unconservative).** No wind or seismic
   reaction, overturning, uplift or sliding reaches any footing on `main`,
   including grade walls carrying shear-wall overturning. The fix is
   written and tested on `row-f-nlp`, not merged. [read]
2. **Uniform drift fix.** Any failing drift check makes every group "need
   thickness" and asks each for `t0 · max ratio` (`_group_needs_thickness`,
   `_drift_scale`). Walls perpendicular to the failing direction or outside
   the failing story band also grow. Grow-only, never relaxed. [read]
3. **Rigid mat strip coefficients** (wL²/10–12, wL²/2 for one span, faces
   as before) remain on `main`; the gate now sends most mats with > 20%
   column-load variation to Winkler, where moments are full-width column-
   strip intensity. Kr omits the superstructure term, so column mats look
   more flexible than ACI 336.2R Eq. 5-2 would make them. [read]
4. **Pierced walls and coupling beams step blind.** A failing segment,
   spandrel or coupling-beam check is filed on the owner wall and counts
   for its group (`_thickness_unresponsive` does not exclude them), but
   `_solid_piers` gives that wall no `WallThicknessTrial`. With no trials
   and drift passing, `_first_passing_thickness` accepts the first inch:
   +1 in per pass until the check passes or the budget ends. Coupling-beam
   failures are better fixed by bars/geometry; thickness is the only lever.
   [read code paths; the stepping behaviour is inferred]
5. **Foundation group envelope** (component-wise max, chaining ±15%,
   c ≥ 18 in) unchanged. [read]
6. **Walls fixed after member change.** W2 re-sizes members on the
   thickened model but never re-checks whether walls could thin. [read]
7. **Row F frame floors persist** for the run (relaxation only on branch).
   [read]
8. **Proxy ignores W growth.** Thicker walls raise W, V, Px and θ; the proxy
   scales drift by t0/t only, so a jump can under-shoot and cost another
   pass (time, not size), or the next pass can over-shoot on a fresh
   uniform ratio. [inferred]
9. **Square spread footings, strip h ≤ 0.5B, worse-axis strip** unchanged.
   [read]

Speed:

1. `_build_second_order`: 4–6 factorizations × up to 3 + nwind + 16 RHS per
   pass, repeated per pass (≤ 7) and per W2 round (≤ 4). [read]
2. `update_analysis!(:geometry)` full rebuild per jump. [read]
3. W2 re-runs the full member stage. [read]
4. Winkler mat linear h sweep with active-set FE solve per inch; the new
   rigid gate routes more mats to it. [read; frequency inferred]
5. W3 12-pass special-wall fixed point per analysis (sectional only, cheap
   per pass). [read]

---

## 7. Open questions

1. Is `row-f-nlp` going to be merged into `main`, and how should its
   monolithic `foundations/utils.jl` edits be reconciled with `main`'s
   uncommitted split? Every Phase 0 foundation item depends on this.
2. On merge, which `wall_footing_kr` survives: `main`'s `wall_plan.jl`
   version (no framed term) or the branch's `foundation_stiffness.jl`
   (framed term)? Should the grade-wall mat also get `framed_I`?
3. Grade-wall footings: should in-plane wall base moments (overturning per
   combination) be carried as `WallLineDemand` samples? Today only vertical
   reactions are.
4. Wall-strip Kr is evaluated at `opts.min_depth`, not the designed h
   (`wall_strip_footing.jl:42`). Intended?
5. Should a failing coupling-beam or spandrel check drive wall thickness at
   all, given it has no trial in the proxy?
6. Should drift drive only walls parallel to the failing direction, and
   should `story_drift_sensitivity` (or a per-direction ratio) replace
   `_drift_scale`? Needs sign-off: it changes which walls grow.
7. With two or more columns and `soil.ks === nothing`,
   `_rigid_mat_inapplicable` returns a reason (spacing cannot be compared
   with 1.75/λ) and `design_footing(::MatFoundation)` then throws, because
   Winkler needs ks. So every column mat on a soil without ks now errors,
   even a rigid one. [read] Acceptable, or should ks be required up front?
