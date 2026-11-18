# Slabs — re-audit 2026-11-18

Scope: every floor system. Paths are abbreviated:
`SS/` = `StructuralSizer/src/`, `SY/` = `StructuralSynthesizer/src/`,
`FP/` = `SS/slabs/codes/concrete/flat_plate/`, `PUN/` = `SS/codes/aci/punching/`.
Working tree on `main` at 7236704d plus uncommitted and untracked files.
Line numbers are hints only. Baseline: `../raw/slabs.md` (2026-11-11).

Most slab files are uncommitted; their last commit predates 11-11 while the
file mtimes are 11-14 to 11-18. "New since 11-11" below is therefore
established by comparing against the baseline text, and is marked
[inferred] where the baseline was silent.

---

## 1. Changes since 2026-11-11

**Flat plate, building level (SY) — column ratchet is now partly relaxable.**
- New member stage `SY/workflow/graph_builder.jl::_design_flat_plate_members!`
  (~:372). An outer `settle!` loop (budget `monotone_budget(max_iterations, 48)`)
  redesigns every slab whose stored design used columns smaller than the
  installed ones (`_stale_flat_plate_slabs`, `_slab_checked_at_installed_columns`
  ~:531), envelopes the column proposals across slabs
  (`_apply_support_envelope!` ~:581), records plan floors
  (`_raise_column_floors!` ~:424), then re-fits sections
  (`_reconcile_columns!` → `check_flat_plate_columns!`). [read] Uncommitted
  (git diff shows the whole function as added), mtime 11-17. [read]
- `SY/workflow/flat_plate_column_check.jl::_fit_flat_plate_columns!` (~:917)
  picks the **lightest** catalog section that passes full-load P-M, the §10.12
  joint check, and punching at the trial plan size, using the stored slab
  demands. With `uniform_column_sizing === :off` (the default,
  `SY/design/parameters.jl:216`) and a stored punching analysis, the floor is
  only `floors[i]`. The installed `c1/c2` is **not** a floor, so a column grown
  by an earlier thin-slab pass can come back down. [read] This is the first
  relaxation of the per-slab punching growth. The baseline had none.
- The punching demand is kept as stored when trying a smaller size. The
  docstring says a smaller column attracts less moment, so the stored demand
  is the conservative one. [read] (`_fit_flat_plate_columns!` docstring
  ~:906-912)

**Flat plate, slab level (SS).** `FP/pipeline/iteration.jl` (last commit 11-11,
not dirty), `punching_resolution.jl`, `column_updates.jl`, `thickness_jump.jl`,
`joint_search.jl`: loop structure unchanged from the baseline. [read]
- Two-way shear capacity now carries the ACI 318-19 size-effect factor:
  `PUN/capacity.jl::size_effect_factor` (λs = √(2/(1+d/10)) ≤ 1, cited
  ACI 318-19 Eq. 22.5.5.1.3). Slab callers pass `λs = size_effect_factor(d)`
  (`FP/design/checks/punching.jl::check_punching_for_column` ~:176, :190,
  :236, :318). [read] For d > 10 in., thickening now helps punching less than
  in proportion to d. [inferred] The general check
  `PUN/general_geometry.jl::punching_check_general` defaults to λs = 1, and the
  waffle head check does not pass λs (see §7). [read]
- The ACI 318-11 §13.5.3.3 increased γf is applied at a column that fails
  Eq. (13-1). `FP/design/checks/punching.jl::check_punching_for_column`
  ~:353-367 → `_increased_transfer_stress` → `PUN/moment_transfer.jl::moment_transfer_gamma_f`.
  The corner case uses γf = 1.0 when Vu ≤ 0.5φVc. [read] (Committed 11-08, so
  it may predate the baseline; the baseline did not mention it.)
- The general punching code is split into new untracked files `PUN/capacity.jl`,
  `check.jl`, `demand.jl`, `general_geometry.jl` and `section_properties.jl`.
  `moment_transfer.jl`, `openings.jl` and `standard_geometry.jl` are tracked. [read]
- FEA: `FP/analysis/fea/cache.jl::fea_mesh_key` now also keys on shape,
  position, orientation, span axis, slab vertices and interior edges.
  `acquire_fea_cache!` replaces a cache whose key differs. [read] Column size
  still forces a remesh (see §2.1.4).

**Waffle / ribbed.** The baseline already recorded the bay-based head loop
(it was annotated on 11-11). Since then [inferred from mtimes and untracked files]:
- New untracked `SY/analyze/slabs/slabs/solid_head_frame.jl::solid_head_frame_punching`.
  It runs a building-frame punching, one-way and hogging check at each solid
  head under full and pattern load, called from `SY/workflow/capture_results.jl:127`.
  It is a report-time check, not in a sizing loop. [read call site; inferred report-only]
- New untracked SS files: `waffle/rib_head_shear.jl` (`check_rib_shear_at_head`,
  `check_rib_hogging_at_head`, `govern_solid_head_checks`),
  `waffle/rib_deflection.jl::scale_rib_deflection` (Ie scaling of grillage
  deflection per ACI 318-11 §9.5.2.3), `solid_head_punching.jl` and
  `solid_head_section.jl`. [read]
- `resolve_arrangement_heads` keeps a step only if the growth ratio falls.
  It marks a head `stuck` and retries the stuck heads after any other head
  grows. A `max_solid_fraction` cap is applied, with the code comment
  "ENGINEERING JUDGMENT". [read] Growth is called from
  `SY/workflow/member_iteration.jl::_iterate_beams_columns!` (~:372) and
  `SY/workflow/check_settle.jl` (~:846). [read]

**Two-way with beams.** `SS/slabs/codes/concrete/min_thickness.jl::min_thickness(::TwoWay)`
cites ACI 318-11 §9.5.3.3 (a)–(d), Eq. (9-12) and (9-13). It adds
`wall_supported` (§9.5.3.3(c) by classification) and `missing_edge_beam`
(§9.5.3.3(d) +10%). [read] The new untracked
`SY/analyze/slabs/slabs/support_classification.jl::classify_two_way_supports`
sets those flags. It rewrites beamless `:two_way` panels to `:flat_plate`
and throws on an interior edge that has neither a beam nor a wall. [read]
The `alpha_fm = nothing` engineering-judgment bound is **still** the only path
used: no caller passes `alpha_fm`. [read] `_size_slab!(::TwoWay)` now takes the
longer of the primary and secondary chords as ℓn, and β = long/short. [read]

**Composite deck.** `SS/slabs/codes/steel/deck_floor.jl` is untracked, with
the same logic as the baseline. New untracked `deck_hogging.jl` adds
ACI 318-19 §6.5 coefficient moments, cantilever moment and negative steel,
but has **no callers in src**. [read] `deck_form.jl` is new. [read file list]

**Unchanged:** one-way (`SS/slabs/sizing.jl::_size_slab!(::OneWay)` ~:711),
vault (`::Vault` ~:807, `SS/slabs/codes/vault/` not dirty). [read]

---

## 2. Flow

### 2.1 Flat plate / flat slab

**Entry.** In SY, `_design_flat_plate_members!` (member stage, wired through
`pipeline_spec`/`graph_builder` at "stage_2_reconcile" ~:328). It calls
`_isolated_floor_outcome` → `SY/floor_design_contracts.jl::design_floor` →
`SS ... pipeline/api.jl::design_floor(request)`. That builds a fresh
`FlatPlateKernelState` from an immutable `FlatPlateDesignInput` and calls
`size_flat_plate!` → `FP/pipeline/iteration.jl::_size_flat_plate!`. [read]

**2.1.1 Analysis choice (once per slab design).** `FP/utils/helpers.jl::resolve_analysis_method`
(~:823) runs once at `iteration.jl:103`. The requested method defaults to
`DDM()` (`SS/slabs/options.jl:320`). If DDM or EFM applicability fails, it
falls back to `FEA()`; an irregular panel or an opening goes to the area
shell `panel_shell()`. [read] The choice is not re-evaluated as the columns
or h change. [read]

**2.1.2 Phase A — depth** (`for iter_a in 1:a_budget`, ~:447).
1. Analysis: DDM closed form, EFM frame (`EFMModelCache`), or FEA shell
   (`FEAModelCache`), with primary and secondary directions. [read]
2. Column P-M: `size_columns` → `column_updates.jl::_update_column_sizes!`
   (`c = max(c_span_min, c_pm, c_old)`, :108-109). A change over 5% re-runs
   the analysis without changing h. [read]
3. Two-way deflection, primary then secondary (ACI 318-11 §9.5.3 / 318-19 §24.2).
4. One-way shear: frame strip, walls, secondary (§11.2 / 318-19 §22.5).
5. Flexural tension control (§21.2.2).
6. §13.5.3 transfer section.

   Any slab failure sets `h = _jumped_depth(...)` (:622/643/675/699/716),
   which calls `thickness_jump.jl::propose_slab_thickness`. [read]

**2.1.3 Phase B — punching** (`for iter_b in 1:b_budget`, ~:750). Steps in order:
re-analysis, then P-M growth, then column punching
(`check_punching_for_column`, ACI 318-11 §11.11.7.1 / PCA EB712), then wall
punching (§11.11.1.2; a failure triggers an h jump at :913 unless joint search
applies). Failures are ordered interior first, then edge and corner (~:923-940).
Then one of two resolvers runs:
- `:joint_search` (when `thickness_scale_applies`, ~:884):
  `joint_search.jl::joint_search` picks (h, per-column size, studs) at minimum
  `material_objective`, with columns at or above their installed size. If h
  changes, Phase A restarts. If only the columns change, Phase B re-analyzes to
  confirm. [read]
- Otherwise `punching_resolution.jl::_resolve_punching_failures!` (:1034)
  runs with strategy `:grow_columns` (default `SS/slabs/options.jl:326`, SY
  `parameters.jl:16`), `:reinforce_first` or `:reinforce_last`. If no size
  within `max_column_size = 30"` passes, it returns `(true, h+0.5")` and the
  caller replaces that with `_jumped_depth(h_before_punch; punching=true)`
  (:1069). [read]

**2.1.4 Phase C** — `final_design.jl::_run_final_design`: primary and
secondary strip rebar, secondary one-way shear on the inner depth, §13.5.3
transfer bars, wall-bar anchorage (§12.12.1, no lever), and integrity
(§13.3.8.5). `needs_more_depth` sets `h += 0.5"`, and the outer loop restarts
Phase A with the columns kept (:1137-1147). [read]

**2.1.5 Variables written on other elements.** `column.c1`, `column.c2`
(Phase A P-M and Phase B growth), the column section and bars (through P-M),
`cell.self_weight`, and the drop panel (h_drop raised to the ACI minimum). These
go back to SY as `FloorSupportUpdate`s. `_commit_floor!` installs the slab
**without** the columns (`install_supports = false`, ~:616). The columns are
installed only through `_apply_support_envelope!`, which takes the governing
update per column across slabs. [read]

**2.1.6 Building loop** (`_design_flat_plate_members!`, ~:372-415):
```
floors = {}                         # per-column plan floor, raise-only
_reconcile_columns!(…; floors)      # lightest passing section; may SHRINK (ucs=:off)
settle!: stale = slabs designed at columns ≠ installed
         before = installed c1,c2
         redesign stale slabs → outcomes (columns grow per §2.1.3)
         _apply_support_envelope!   # install governing proposal per column
         _raise_column_floors!      # if c grew vs `before` → floors[i] = max(floor, c)
         sync_asap!; _reconcile_columns!(…; floors); _harmonize_columns!
```
[read]

### 2.2 Column ratchet — exact mechanism

1. **Growth is decided** in `FP/pipeline/punching_resolution.jl::_resolve_punching_failures!`.
   With `:grow_columns`, `_grow_to_passing!` (~:200) scans
   `_column_candidates` (~:167) toward the target from
   `FP/utils/column_growth.jl::solve_column_for_punching` (~:157,
   `b0_req = b0·ratio`, "never shrink"). Each candidate is rechecked with the
   **frozen** Vu/Mub from the current analysis. The first passing size is
   kept. [read]
2. **At the cap.** If no candidate up to `c_max` passes, *that* column is
   restored (`_grow_to_passing!` resets c1/c2, ~:212). Columns grown
   **earlier in the same pass are not restored** before `return (true, h)`
   (~:134-137). [read] The outer loop then keeps all columns
   (`column_updates.jl:108-109` `max(…, c_old)`; Phase A reruns with them). [read]
   So within one slab design the ratchet is: grown at the thin h, kept at
   the thicker h. [read]
3. **Recorded as a floor in SY.** `SY/workflow/graph_builder.jl::_raise_column_floors!`
   (~:424-435): a column that came out of a round larger than `before`
   (+0.05 in tolerance) gets `floors[i] = max(floors[i], (c1, c2))`. `floors`
   lives for the whole `_design_flat_plate_members!` call and only rises. [read]
4. **What relaxes it now.** `SY/workflow/flat_plate_column_check.jl::_fit_flat_plate_columns!`
   with `uniform_column_sizing === :off` and a stored punching analysis
   (`_column_punching_demands` ~:710) searches down to `floors[i]` only, not to
   the installed size (~:926-939). It checks punching at the trial size with
   the stored Vu and Mub (stored at the larger column, conservative per the
   docstring). Two consequences:
   - A column grown in the per-slab Phase B but never re-grown in an SY round
     has no floor, so it can be shrunk to the lightest size that passes
     punching **at the final h** (the stored `design_details` h). This removes
     the thin-slab ratchet. [read logic; inferred effect]
   - That shrink makes the slab stale. The redesign starts again at the ACI
     minimum h with the smaller column [inferred: no `min_h` is passed from SY,
     grep]. The redesign may grow the column again at the thin h. Then
     `_raise_column_floors!` fixes that thin-h size as a **permanent floor**.
     The ratchet is moved to the building level rather than removed.
     [inferred]
   - With `uniform_column_sizing ≠ :off`, or with no stored analysis, the floor
     is `max(floor, installed)`: no relaxation. [read]
   - Inside a single SS slab design (`_size_flat_plate!`) nothing relaxes. [read]

### 2.3 Does growing a corner column lower its punching ratio?

Mechanism in `FP/design/checks/punching.jl::check_punching_for_column` (~:80-384). [read]
- Corner stress (~:322-332):
  `vu = Vu/(b0 d) + Σ_axis γv·(|M| − Vu·e)·c/Jc`, with `shifted_moment_stress`,
  `e = eccentricity_to_critical_centroid(b1, c1, cAB)`,
  `Jc = polar_moment_Jc_corner` (PCA EB712 Fig. 16-13 Case D), and
  `γv = gamma_v(b1, b2)`.
- With growth c → c+Δ (Vu and M frozen in the resolver):
  - b0 = b1 + b2 grows linearly, so the direct-shear term falls.
  - Jc grows roughly with the cube of b, so the moment term per unit moment
    falls faster.
  - The centroid offset e grows, so `|M| − Vu·e` falls.
  - γv for a square corner does not change with size.
  - φvc changes only through β (aspect ratio) and the αs·d/b0 term: for a
    corner, αs = 20, so (2 + 20d/b0) falls as b0 grows and can govern for
    large c/d. [inferred from `punching_capacity_stress` form]
  With demands frozen, the computed ratio falls monotonically with c in the
  resolver. [inferred]
- **Not captured in the resolver:** column stiffness. EFM and FEA give the
  column stub `I_factor·Ig` (∝ c⁴), and FEA also adds a rigid patch
  (`patch_stiffness_factor = 100` over the column footprint,
  `FP/analysis/fea/model.jl`). A larger corner column attracts more
  unbalanced moment at the next analysis. Phase B re-analyzes after any
  growth (`columns_grew → continue`, iteration.jl ~:1076) and can fail again.
  The step sequence is then: grow, re-analyze, grow, until `c_max`, and then
  an h jump with the grown columns kept. [read loop; inferred dynamics] DDM's
  unbalanced moment depends on c only through ℓn and the §13.6.3 coefficients,
  so the feedback is weak there. [inferred]
- **Relief valve:** §13.5.3.3(a) (`PUN/moment_transfer.jl::moment_transfer_gamma_f`,
  case `:corner`) sets γf = 1.0, removing eccentric shear, when Vu ≤ 0.5φVc and
  the band bb develops the moment as tension-controlled. It is taken only
  when Eq. (13-1) fails (~:353-367). Growing a corner column raises φVc
  (through b0), so it can switch this provision on. The effective ratio is then
  Vu/(φvc·b0·d), and the moment goes to band steel. [read]
- `solve_column_for_punching` sizes by `b0_req = b0·ratio` (perimeter scaling).
  Its comment says this is "conservative for concentric term". It ignores the
  Jc and e effect, which pushes the target up. The candidate scan then stops at
  the first passing size, so the overshoot is bounded by `size_increment`. [read]

### 2.4 FEA model cache and remesh

- Cache home: `struc._analysis_caches[slab_idx][:fea]`, `iteration.jl:229-251`.
  The SY member stage designs through a fresh `FlatPlateKernelState` per
  request (`pipeline/api.jl:134`), so every slab redesign starts with an
  uninitialized cache. That means at least one rebuild per slab design per SY
  round. [read constructor call; inferred empty Dict]
- Key: `FP/analysis/fea/cache.jl::fea_mesh_key` (~:160-186). It covers slab
  boundary xy, vertex ids, interior edges, and for each column (x, y, **c1, c2**,
  shape, position, orientation), plus cell spans, `target_edge`, drop
  (h_drop, a1, a2) and span axis. **h and E are not in the key.** [read]
- `FP/analysis/fea/precompute.jl::_build_or_update_fea!` (~:121) does a full
  reset and rebuild when the key changes (~:146-151), when the edge-beam
  topology toggles (~:157-169), or when the drop panel changes (~:203-215).
  Otherwise it takes the update path, `_update_and_resolve!` (new h, E, column
  stub sections, then a re-solve). [read]
- **Column size forces a remesh: yes.** It is in the key, and the refinement
  edge is `clamp(min_col_dim/2, 0.04 m, target/2)` (`model.jl:348`). The
  default `target_edge = clamp(min_span/20, 0.15, 0.30) m` (`model.jl:297`). [read]
- Solves per analysis: one factorization, then the D and L load cases by
  `Asap.update!(model; loads_only=true)` and back-substitution
  (`load_cases.jl::_solve_load_case!` ~:60-70). The factored state is restored
  from a snapshot or with one extra solve (`_solve_dl_cases!` ~:120-145).
  FEA-native pattern loading adds per-cell solves on the same factor. [read]
- Rebuilds vs updates per slab design (counters `n_rebuilds`, `n_updates` are
  emitted as `fea_rebuilds`/`fea_updates` on the `:slab` exit event,
  `iteration.jl:357-361`, :1135):
  - rebuilds = 1 + (Phase A P-M column changes) + (Phase B growth rounds)
    + (joint-search column changes) + (drop resizes);
  - updates = (h-only changes, i.e. jump confirms and Phase C restarts with no
    column change).

  Under `:grow_columns` with FEA, most analyses after the first are rebuilds.
  [inferred from key + loop]

### 2.5 Two-way with beams
`SY/.../support_classification.jl::_apply_two_way_supports!` (before sizing)
→ `SS/slabs/sizing.jl::_size_slab!(::TwoWay)` (~:752) →
`_size_span_floor(TwoWay())` → `min_thickness(::TwoWay; alpha_fm=nothing, wall_supported, missing_edge_beam)`.
The result is h rounded up. `assign_panel_analysis!` records the analysis
method only. No strength checks and no loop. Writes `slab.h` and
`cell.self_weight`. No writes to columns or beams. [read]

### 2.6 One-way and joists
`_size_slab!(::OneWay)` (~:711): ACI 318-11 Table 9.5(a) by the support
condition (thickest over the cells), with the cantilever override at unframed
openings. `assign_panel_analysis!` records the §8.3.3 coefficients or the area
shell. Bars are not sized. No loop. [read] Joists and ribs are sized as beams in
the members area (`size_beams!`). [inferred: outside this area]

### 2.7 Waffle / ribbed (rib frame + solid heads)
- The topping or form depth comes from `SS/slabs/codes/concrete/sizing.jl::_size_span_floor(::Waffle)`
  (~:340): the first standard form depth ≥ `min_thickness(Waffle(), ln)`. [read]
- Ribs are sized as beam members. Then, inside
  `SY/workflow/member_iteration.jl::_iterate_beams_columns!` (~:351), each pass
  runs: `size_beams!` → `raise_head_face_ribs!` → `conform_rib_lines!` →
  `SY/analyze/framing/solid_head_split.jl::grow_building_solid_heads!` (~:705)
  → re-analysis → `size_columns!`. [read]
- `grow_building_solid_heads!`: heads start from `level.solid_heads` if set,
  otherwise from `_initial_solid_heads` (corner fraction plus bays around
  uncovered columns), so heads persist across passes. It closes tight voids
  and then calls `SY/analyze/slabs/slabs/arrangement_heads.jl::resolve_arrangement_heads`
  (~:357). [read]
- `resolve_arrangement_heads` loop: `analyze_arrangement_grillage` (an Asap
  frame of the rib arrangement plus column stubs, fixed base, stub size =
  smallest column face on the slab, height 3 m) → `check_arrangement_head`
  per head (~:257):
  1. column punching at d/2 outside the outline (`punching_check_general`,
     ACI 421.1R-99 App. B demand, ACI 318-11 §11.11.2.1 capacity);
  2. rib one-way shear at d from the face (§11.1.3.1);
  3. stem hogging compression at the face.

  The worst failing head grows one bay or ring
  (`grow_checked_column_head`). The trial is re-solved and kept if its ratio
  falls. Stops: all pass, all stuck, or the solid cap. [read]
- Writes: `level.solid_heads`, and beams moved into the solid-head group
  (`_expand_solid_to_heads!`, `apply_solid_head_frame_sections!` → beam
  sections). It reads `column.c1/c2` (`_slab_column_size`) but **does not
  write columns**. [read]
- Report-time check: `solid_head_frame_punching` (capture_results). [read]

### 2.8 Composite deck
`_size_slab!(::CompositeDeck)` (~:519): SDL and LL are the maximum over the
cells. `deck_floor.jl::size_composite_deck_slab` (~:198) enumerates the
tabulated depths × `_BEARING_GAGES`. Each candidate runs
`deck_slab_candidate` (~:68): §2.4.B.6 f′c and topping minimums → unshored
span → web crippling (if bearing given) → M_asd = wL²/8 ≤ Mno/Ω (cantilever
wL²/2 per SDI item 13) → shear ≤ min(SDI Eq. 2.4.7, Vno/Ω) → live deflection
and optional superimposed deflection (Es = 29,500 ksi, Appendix 5). The
lightest passing candidate is chosen. Writes `cell.self_weight`. [read]

### 2.9 Vault
Unchanged from the baseline: Haile analytic thickness bisection or a
rise × thickness grid. Writes `slab.result`. Thrust goes to the members area.
[read sizing.jl dispatch; internals per baseline]

---

## 3. Loops

| id | anchor | iterates | budget | growth | converges when | writes | ratchet |
|---|---|---|---|---|---|---|---|
| fp.outer | `FP/pipeline/iteration.jl::_size_flat_plate!` ~:438 | h (restart) | `monotone_budget(max_iter, h-steps to ln/10)` | grow-only | Phase C passes | slab.h, column.c1/c2 | **yes**: columns carried across h restarts [read] |
| fp.phase_a | same, ~:447 | h; columns via P-M | same | grow-only | all Phase A checks pass | slab.h, column.c1/c2, h_drop | yes: P-M growth at thin h kept [read] |
| fp.thickness_jump | `thickness_jump.jl::propose_slab_thickness` | h candidates (0.5") | ≤ ln/10 | grow-only | first passing scaled candidate | slab.h | no (no state) [read] |
| fp.column_pm | `column_updates.jl::_update_column_sizes!` | c1, c2 | shares A/B budget | grow-only (`max(c_span_min,c_pm,c_old)`) | no change > 5% | column.c1/c2, bars | yes [read] |
| fp.phase_b | `iteration.jl` ~:750 | columns, studs, h | `monotone_budget(max_iter, column steps)` | grow-only | all punching OK | column.c1/c2, studs, slab.h | **yes**: grown columns kept when h jumps [read] |
| fp.punching_resolver | `punching_resolution.jl::_resolve_punching_failures!` / `_grow_to_passing!` | per column size | to `max_column_size` (30") | grow-only | first candidate passing with frozen demand | column.c1/c2, studs, caps | yes: earlier columns in the pass not reset on h bump [read] |
| fp.joint_search | `joint_search.jl::joint_search` | (h, per-column size, studs) | grid up to ln/10 | free+guard (columns ≥ installed) | min objective; confirm analysis | slab.h, column.c1/c2, studs | low: floor = installed sizes [read] |
| fp.phase_c_restart | `final_design.jl::_run_final_design` → iteration.jl ~:1137 | h += 0.5" | outer budget | grow-only | rebar, shear, transfer pass | slab.h | yes: columns kept [read] |
| fp.efm_hardy_cross | `FP/analysis/efm/moment_distribution.jl` | joint moments | 20 iters, tol 0.01 | n/a | Δ < tol | — | no [baseline; file dirty, not re-read] |
| sy.fp_member_settle | `SY/workflow/graph_builder.jl::_design_flat_plate_members!` ~:384 | stale slabs → columns | `monotone_budget(max_iter, 48)` | free+guard (shrink in reconcile, floors raise-only) | no slab stale | column.c1/c2/section, slab results, `floors` | **yes**: `floors` raise-only for the call [read] |
| sy.fp_column_fit | `SY/workflow/flat_plate_column_check.jl::check_flat_plate_columns!` ~:993 | column section | `monotone_budget(max_iter, catalog size)` | free+guard (down to `floors` when ucs=:off) | no section changed | column.section, c1/c2 | partial: relaxes per-slab growth, not `floors` [read] |
| sy.waffle_heads | `SY/analyze/slabs/slabs/arrangement_heads.jl::resolve_arrangement_heads` ~:381 | bays per head | one step per bay (throws past it) | grow-only | all heads pass / all stuck / solid cap | head bays | **yes**: starts from `level.solid_heads` each pass [read] |
| sy.waffle_member_pass | `SY/workflow/member_iteration.jl::_iterate_beams_columns!` ~:355 | ribs, heads, columns | `max_iterations` | per member rules | sections unchanged | beam/column sections, heads | heads grow-only [read] |
| vault.thickness | `SS/slabs/codes/vault/haile_unreinforced.jl::_find_min_thickness` | t (5 mm grid) | log₂ n | bisection | feasibility edge | slab.t | no [baseline] |
| vault.grid | `SS/slabs/optimize/api.jl::optimize_vault` | rise × t | 20×20 + 2 refines | free | grid best | rise, t | no [baseline] |

Two-way, one-way and composite deck have no loop (deck is an exhaustive
enumeration). [read]

---

## 4. Writers

| variable | writer | rule |
|---|---|---|
| slab.h (flat plate) | `iteration.jl::_size_flat_plate!` (init ACI min / fire / `opts.min_h`), `_jumped_depth`, Phase B h bump, Phase C `+h_increment`, `joint_search` best.h | max (grow-only within a design) [read] |
| column.c1/c2 (per slab) | `column_updates.jl::_update_column_sizes!` | `max(c_span_min, c_pm, c_old)` [read] |
| column.c1/c2 (per slab) | `column_updates.jl::_initialize_unsized_columns!` | init from P-M, ≥ 14" [read] |
| column.c1/c2 (per slab) | `punching_resolution.jl::_grow_to_passing!` | replace by the first passing candidate ≥ current [read] |
| column.c1/c2 (per slab) | `iteration.jl` joint-search install ~:1000 | replace with `best.columns` (≥ installed) [read] |
| column.c1/c2 (building) | `graph_builder.jl::_apply_support_envelope!` → `_install_governing_support!` | governing proposal across slabs [read] |
| column.c1/c2/section (building) | `flat_plate_column_check.jl::_fit_flat_plate_columns!` | replace by the lightest passing; floor = `floors[i]` (ucs=:off with stored demand), else `max(floors[i], installed)` [read] |
| column floors | `graph_builder.jl::_raise_column_floors!` | max, raise-only [read] |
| column (uniform) | `_harmonize_columns!` → `harmonize_uniform_column_sizes!` | group max [read call] |
| studs / caps / capitals | `_try_reinforcement`, joint search | replace per pass [read] |
| drop h_drop, a1, a2 | `iteration.jl` ~:137-170, ~:474-505; `sizing.jl::auto_size_drop_depth` | raise to the ACI minimum only [baseline; not re-read] |
| cell.self_weight | `_install_span_result!` (one-way, two-way), `_size_slab!(::CompositeDeck)`, FP cell updates | replace [read] |
| slab.h (two-way) | `min_thickness(::TwoWay)` via `_size_span_floor` | replace (bound when αfm unknown) [read] |
| slab.h (one-way) | `_size_slab!(::OneWay)` | max(bay, cantilever) [read] |
| deck depth × gage | `size_composite_deck_slab` | argmin weight [read] |
| waffle head bays | `resolve_arrangement_heads` / `grow_building_solid_heads!` | grow-only from the previous heads [read] |
| beam section (solid-head ribs) | `_expand_solid_to_heads!`, `apply_solid_head_frame_sections!`, `assign_solid_head_sections!` | replace by the solid section [read] |
| two-way flags | `classify_two_way_supports` → `_apply_two_way_supports!` | replace spec floor_type / flags [read] |

---

## 5. Fast-tier inventory (F.1)

**Flat plate / flat slab.**
- Method choice is embedded in the designer: `resolve_analysis_method` is
  called inside `_size_flat_plate!` (iteration.jl:103), and every
  `_moment_analysis` call sits inside Phases A/B/C. [read] There is no
  injection point for an external demand source. [read]
- Pure check functions of (geometry, size, demands):
  - `check_punching_for_column`
  - `punching_check_general`
  - `phase_a_depth_passes` (deflection, one-way shear, flexure, transfer)
  - `punching_depth_passes`
  - `moment_transfer_gamma_f`
  - the stud, cap and capital designers
  - `design_strip_reinforcement`

  They take a `MomentAnalysisResult` plus h, d, f′c and the columns. [read]
  The thickness jump and the joint search already use them on scaled demands. [read]
- What scales today: `thickness_jump.jl::scale_moment_result` multiplies
  all `_SCALED_DEMAND_KEYS` by `r = qu(h)/qu(h0)` and the gross displacement by
  `r·(h0/h)³` (`loads_at_thickness`). The column sizes are frozen.
  `thickness_scale_applies` refuses the scale for drop panels, pattern
  loading, and h-dependent edge-beam βt. [read]
- Superposition of unit cases: the FEA already solves D and L as separate load
  vectors on one factorization (`_solve_dl_cases!`), plus per-cell live
  patterns (`load_cases.jl`). [read] Linear analysis means that for a fixed
  stiffness, demands = qD·M_D1 + Σ qL,i·M_Li exactly. So pattern loading
  could be scaled per case instead of refused. [inferred]
- What breaks exact scaling:
  - Slab stiffness ∝ h³ while column stubs ∝ c⁴: the distribution of
    unbalanced moment between slab and column changes with both h and c. The
    current scale ignores this; one confirm analysis absorbs it. [inferred]
  - FEA remeshes when c changes, so a "unit case per geometry" must hold the
    mesh fixed. That means modelling column growth as a stiffness change on a
    mesh refined for `c_max`. [inferred]
- A fast demand source would need, per slab geometry: unit D and per-cell
  unit-L moment, shear and unbalanced-moment fields (Vu, Mub per column and
  direction, strip moments, face moments, wall transfer). Optionally it would
  also need first-order sensitivities to the column stiffness ratio. It would
  emit a `MomentAnalysisResult`. [inferred]
- Blocks:
  1. analysis and checks are interleaved in `_size_flat_plate!`;
  2. the mesh key includes column size;
  3. the SY round recreates the kernel state, so the cache is not reused;
  4. Phase C FEA extraction (strip and area design) reads the cache directly
     (`_run_final_design` with `analysis_cache`).

  [read]

**Waffle.**
- The analysis is a discrete grillage frame (`analyze_arrangement_grillage`),
  run once per trial head step. [read] No smeared orthotropic plate model exists
  in SS or SY (grep for "orthotropic" or "smeared" finds only walls and
  detailing). [read]
- Asap has `external/Asap/src/Materials/layup.jl` (Ply, Laminate, ABD,
  `laminate_stiffnesses`, transverse shear) used by composite shells.
  [read] An equivalent orthotropic plate (D_x, D_y, D_xy from rib EI and
  spacing) could reuse that shell. [inferred] Solid heads would be isotropic
  patches, as `patch_stiffness_factor` already does for columns. [inferred]
- Pure checks: `check_rib_shear_at_head`, `check_rib_hogging_at_head`,
  `punching_check_general` on `column_head_section`, and
  `scale_rib_deflection`. Each takes demands plus geometry. [read]
- Block: head growth changes the frame sections, so each step re-solves. A
  fast tier could rank head steps with the punching ratio scaled by b0 and Jc
  at fixed demand, then confirm. [inferred]

**Two-way / one-way / deck / vault.** These are closed form or enumeration:
- Two-way and one-way are pure functions of span, support class and fy. [read]
- The deck is a pure function of span, sdl, live and the profile. [read]
- The vault is a pure function of span, load and rise. [read]

No analysis to separate. Two-way would need αfm from the beam sizes. [read]

---

## 6. Size-impact and speed findings (ranked)

1. **Size, HIGH — the building-level column floor re-locks the thin-slab
   size.** `_raise_column_floors!` records any growth seen in a redesign round.
   Redesigns start at the minimum h with the shrunk column [inferred], so the
   recorded floor is the thin-slab punching size. That is the same ratchet one
   level up, now permanent for the stage. Evidence: graph_builder.jl ~:384-435,
   `_fit_flat_plate_columns!` floor logic ~:934-939. [read + inferred]
2. **Size, HIGH — the per-slab Phase B ratchet is unchanged.** `:grow_columns`
   is still the default (SS options :326, SY parameters :16). Columns grown
   earlier in the pass are kept on an h bump (`punching_resolution.jl` ~:134-137).
   The columns carry across restarts (`column_updates.jl:108-109`). [read]
   Mitigated only when ucs=:off and the SY fit shrinks them. [read]
3. **Size, HIGH — two-way thickness still uses the αfm-unknown bound.**
   `min_thickness.jl` ~:198-203; no caller passes `alpha_fm`. [read]
4. **Speed, HIGH — FEA rebuilds per column change.** The mesh key includes
   c1/c2 (cache.jl ~:169-173), so every Phase A P-M change and every Phase B
   growth round is a full mesh, assembly and factorization. Each SY round
   redesigns stale slabs from a fresh kernel state, so its cache is cold.
   [read + inferred] The FEA fallback is automatic whenever DDM/EFM is
   inapplicable. [read]
5. **Speed, MED-HIGH — the SY settle loop multiplies slab designs.** Each
   round redesigns every stale slab in full (Phase A/B/C). After a reconcile
   shrink, a slab is stale by definition. Budget up to 48 rounds. [read]
6. **Size, MED — corner and edge growth under stiffness feedback.** The
   resolver uses frozen demand, but EFM and FEA re-analysis increases Mub with
   c⁴ stub stiffness. Growth can run to `c_max` and then thicken, keeping the
   grown size. §13.5.3.3(a) can cut this off once Vu ≤ 0.5φVc. [read mechanism;
   inferred dynamics]
7. **Size, MED — flat slab, pattern loading and edge-beam βt drop out of
   scaling and the joint search.** They fall back to +0.5" steps and the
   greedy resolver. `thickness_jump.jl::thickness_scale_applies` ~:51-57. [read]
8. **Speed, MED — waffle head loop.** It runs two grillage solves per accepted
   step (base + trial, `resolve_arrangement_heads` ~:382, ~:441), retries
   stuck heads after any growth, and sits inside the member pass loop. [read]
9. **Size, LOW-MED — composite deck uses simple-span wL²/8 always.**
   `deck_hogging.jl` (continuity, ACI 318-19 §6.5) is unwired. [read]
10. **Size, LOW-MED — λs inconsistency.** Flat-plate punching applies λs(d);
    the waffle head punching (`check_arrangement_head` → `punching_check_general`)
    uses the default λs = 1. [read] See §7.

---

## 7. Open questions

1. **Ratchet policy (sign-off).** Should `_raise_column_floors!` floors be
   cleared when the slab's h later rises, or should a redesign start from the
   slab's last h (pass `min_h`), so a floor reflects the final h? Today
   neither happens. [read]
2. **Per-slab reset.** On a Phase B h bump, should columns grown earlier in
   the same resolver pass go back to their Phase A sizes? The baseline
   proposed this; it is not implemented. [read]
3. **Stored-demand assumption in `_fit_flat_plate_columns!`.** The docstring
   says a smaller column takes less unbalanced moment, so the stored Mub is
   conservative. Vu also changes slightly (the load inside the critical
   section). Is the assumption accepted for edge and corner columns, where the
   centroid shift `Vu·e` also shrinks with c? A smaller e gives a *larger*
   `|M| − Vu·e`. The stored M is conservative, but the e term is recomputed at
   the trial size, so this is consistent. Confirm. [inferred]
4. **Waffle punching αs and λs.** `check_arrangement_head` uses
   `αs = closed ? 40 : 30` and no `λs`. An open corner section and the size
   effect are not distinguished, while flat plates pass `λs = size_effect_factor(d)`.
   Which code edition should govern the waffle head capacity? [read; ask before changing]
5. **Mixed editions.** Flat-plate punching combines ACI 318-11 §11.11 and
   §13.5.3.3 demand and transfer with the ACI 318-19 λs. The
   `moment_transfer_gamma_f` docstring argues this never loosens §13.5.3.3.
   Sign-off needed. [read]
6. **Two-way αfm.** Should two-way slabs be re-sized with the real αfm after
   the beams are sized (a two-pass loop)? [read: not implemented]
7. **FEA cache reuse across SY rounds.** Is a cold cache per redesign
   intended (immutable request contract), or should the kernel accept a
   workspace FEA cache like `column_cache`? [read contract; inferred intent]
8. **`solid_head_frame_punching`** is it report-only, or should a failure feed
   back into head growth? [inferred report-only]
