# Pipeline audit, 2026-11-18

Area: `pipeline`, the building-level workflow of `design_building`. It covers
entry, prepare and the element split, the stage graph and scheduler, barrier
syncs, the member-stage dispatch (flat plate and beam), the walls ⇄ members
recheck, the entry to foundations, capture and restore, and the shared settle
driver.

Baseline: [`../raw/building-pipeline.md`](../raw/building-pipeline.md)
(2026-11-11). This report reads the working tree as it is on 2026-11-18,
including uncommitted and untracked files. `git HEAD` is a chain of
memory-only commits and does not show the 11-11 source state, so every
comparison here is against the baseline report, not against a git diff.

Paths: `SY/` = `StructuralSynthesizer/src/`, `SS/` = `StructuralSizer/src/`.
Line numbers are hints only.

---

## 1. Changes since 2026-11-11

### 1.1 Loops and rules that changed

1. **The full-load flat-plate column check is now a two-sided section search
   (baseline L6).** [read] `SY/workflow/flat_plate_column_check.jl::check_flat_plate_columns!`
   (:993) no longer calls `_grow_flat_plate_columns!`. It calls
   `_fit_flat_plate_columns!` (:917). For every checked column, that function
   binary-searches catalog plan sizes (`_catalog_plan_groups` :673,
   `_lightest_passing_group` :872). It installs the lightest section that
   passes four things: full-load P-M in both orientations, the §10.12 joint
   sections, the flat-plate cap, and **punching at the trial plan size**
   (`_punching_passes_at` :779, using the slab's stored `column_shears` and
   `unbalanced_moments`). When `uniform_column_sizing === :off` (the default)
   and a stored punching demand exists, the search can go **below** the
   current size. Its only floor is the `floors` dict, a plan size the slab
   reanalysis had to grow the column back to (:935-939). Otherwise the
   current size is the floor, which is the old grow-only behavior. Memory
   decision `deci-0f9ac6c8` (2026-11-17) records the intent.
2. **Column stacking (lower ≥ upper) is no longer applied (baseline L7).**
   [read] `_stack_flat_plate_columns!` (:492) and `_grow_flat_plate_columns!`
   (:615) have no callers anywhere in `SY/` (grep). `check_flat_plate_columns!`
   only reports `nonmonotone` (`_non_monotone_columns` :560). Its docstring
   says "A column is not required to be at least as large as the column
   above it" (:984-985). Both functions are dead code.
3. **The flat-plate member stage was reordered and gained a floor memory
   (baseline L4).** [read] `SY/workflow/graph_builder.jl::_design_flat_plate_members!`
   (:372). It now runs `_reconcile_columns!` and `_harmonize_columns!` once
   **before** the stale-slab settle loop (:379-380). Each round redesigns the
   stale slabs, applies the support envelope, then calls
   `_raise_column_floors!` (:424). That function records any column the slab
   redesign grew, as `floors[i] = max(floor, c)`. The round then runs
   `sync_asap!`, `_reconcile_columns!` (with `floors`), and harmonize. Floors
   are local to one call of the member stage.
4. **The beam ⇄ column loop no longer runs to its budget in a 2-cycle
   (baseline L9).** [read] `SY/workflow/member_iteration.jl::_iterate_beams_columns!`
   (:351) keeps a `history` of `_MemberState`s. When a state repeats, it
   calls `SY/workflow/check_settle.jl::_check_settle!` (:476). That function
   re-analyzes each state in the cycle and checks every beam and column
   group with the sizer's own checker, pinned to the installed section
   (`_pinned_failures` :152). It installs the cheapest state that fully
   passes. If none passes, it tries a per-group mix (`_mixed_state`: the
   cheapest section that passed in some state, else the costliest). Failing
   groups are then resized up to 3 times (`_resize_failures!` :443).
5. **Each pass of the beam loop now also runs rib and solid-head steps.**
   [read] `raise_head_face_ribs!`, `conform_rib_lines!` and
   `grow_building_solid_heads!` run inside every pass (member_iteration.jl
   :366-372) and inside `_resize_rejected!` (check_settle.jl :840-846). They
   only raise or grow (docstrings `SY/analyze/members/members/rib_variation.jl::raise_head_face_ribs!`,
   `SY/analyze/framing/solid_head_split.jl::grow_building_solid_heads!`).
6. **The story-shell rounds changed (baseline L11).** [read]
   `_size_with_story_shell!` (member_iteration.jl :437). When the options are
   "checkable" (`_round_checkable`, check_settle.jl :760: discrete,
   single-material, `n_max_sections == 0`, non-composite steel), the rounds
   **break after round 1** (:501). `_reconcile_shell_frame!` (check_settle.jl
   :862, up to 4 attempts) then solves the shell on the installed sections,
   keeps groups that pass, and resizes only the failing ones
   (`_resize_rejected!` :800). Passing column groups are put back after the
   column MIP re-picks them (`_restore_passing_columns!`). Non-checkable
   options keep the old 3-round loop with the `upward_only` floor.
7. **`design_building` now runs the incremental scheduler by default.**
   [read] `SY/workflow/execute.jl::design_building` (:222) builds a
   `DesignSession` (`SY/design_graph/session.jl::DesignSession` :77). That
   calls `prepare_engine` and then `run_target!`
   (`SY/design_graph/scheduler.jl` :234, :425), not `execute_graph!`. Only
   `restore=false` uses the old in-place path (`_design_building_inplace`,
   execute.jl :144 → `execute_graph!`). The scheduler snapshots the whole
   structure after every dirty level and fingerprints each dirty node's
   outputs. See §6.
8. **The seed is clamped to the flat-plate column cap.** [read]
   `SY/workflow/prepare.jl::prepare!` (:153-158) passes
   `max_size = max_column_size` (default 30", `SS/slabs/options.jl:328`).
   `estimate_column_sizes!` clamps c1 and c2 to it
   (`SY/analyze/members/members/size_columns.jl` :623-626).
9. **The shared iteration driver has new callers.** [read]
   `SS/iteration.jl` (untracked) defines `growth_steps`, `monotone_budget` and
   `settle!`. `settle!` now drives the lock (L3), the flat member stage (L4),
   the column fit (L6) and the wall jump (L12). The column fit is no longer
   monotone (item 1) but still takes `monotone_budget(max_iterations, length(catalog))`.

### 1.2 Correction to the baseline

- **The default column seed is `start = :axial`, not `:span`.** [read]
  `SS/slabs/options.jl:336` defaults `column_span_minimum = false`, and
  `prepare!` maps that to `:axial` (prepare.jl :155-156). The default seed is
  therefore max(axial area at ρg = 0.01 over every floor above, 14"), clamped
  to the 30" cap. The building-average span/15 applies only when the floor
  options turn on `column_span_minimum`. The same flag disables the span/15
  floor inside the slab kernel (`SS/slabs/codes/concrete/flat_plate/pipeline/column_updates.jl::_column_span_minimum`
  :37). Memory shows the default was already `false` on 2026-11-08, so the
  baseline's top-5 item 1 overstated the span/15 effect.

### 1.3 Unchanged in substance

- The walls ⇄ members recheck (L13), including the frame-column overstress
  floor (`_floor_overstressed_frame_columns!`, `SY/workflow/pipeline_spec.jl`
  :220), which baseline edge 9 already described. [read]
- The shared-column propose → envelope → commit → lock (L2, L3). [read]
- The legacy `size!` (L15, `SY/core/size.jl::size!` :39) and the scheduler's
  `_adopt_larger_column!` (L16, `SY/core/snapshot.jl` :484) still exist. [read]

---

## 2. Flow

### 2.1 Entry

`design_building(struc, params)` (`SY/workflow/execute.jl` :222) [read]:

- With `restore = true` (the default), it builds a `DesignSession` (session.jl :77):
  1. `resolve_design_context`.
  2. `prepare_engine` (scheduler.jl :234). This deep-copies the caller's
     `struc` (`capture_node_state`), runs `prepare!`, runs
     `run_pre_sizing_validation`, runs `build_design_graph`, captures a
     second deep copy as the baseline, and restores a third deep copy as the
     working structure.
  3. `run_target!(engine, params)` (:425). This rebuilds the graph a second
     time, restores the baseline once more, then walks the topological
     levels: run the dirty nodes, barrier `sync_asap!` if any dirty node
     needs it, snapshot, and hash.
  4. `capture_incremental_design` → `capture_design`.
  5. `_finish_design_model!`, which builds the scene or ports the solved frame.

  The caller's `struc` is never mutated, so `restore!` is not called.
- With `restore = false`, it calls `_design_building_inplace` (:144):
  `prepare!` → validation → `build_design_graph` → `execute_graph!`
  (`SY/design_graph/executor.jl` :39) → `capture_design` → no `restore!`.

### 2.2 Prepare and the element split

`SY/workflow/prepare.jl::prepare!` (:85) runs these steps in order [read]:

1. `_qualify_module_framing`, `resolve_floor_options`, `_infer_floor_type`.
   The rib/joist plan is resolved before the support check.
2. `apply_facade_setback!`, unless `geometry_is_centerline`.
3. `initialize!` (`SY/core/initialize.jl` :35) performs the element split:
   - `find_faces!` and `frame_slab_openings!` (beam floors get trimmers and
     headers before cells are cut), then `rebuild_geometry_cache!`.
   - `initialize_cells!`: one cell per floor face, carrying sdl, live and
     spans.
   - `initialize_slabs!`: cells are grouped into slabs by the floor option's
     grouping or scoped overrides. A beamless `:two_way` panel is reclassified
     `:flat_plate` and merged into one slab per story
     (`SY/analyze/slabs/slabs/support_classification.jl::_apply_two_way_supports!`
     :169, `_merge_reclassified_flat_plates` :259). [read]
   - `initialize_segments!`, `update_bracing!`.
   - `initialize_members!` (`SY/analyze/members/members/initialize.jl`).
     Each edge chain becomes a `Column`, `Beam`, `Strut`, a `Wall` (from the
     `:walls` group, at `wall_thickness`), or nothing (an `:absent` edge).
     Beam roles are classified, then `link_column_stack!` sets
     `column_above`, `compute_column_tributaries!` sets the columns'
     tributary cells, and `link_wall_stack!` runs. [read]
   - `assert_one_way_slabs_supported`, `compute_slab_parallel_batches!` (no
     longer shapes the graph; graph_builder.jl :33-37),
     `assert_story_walls_enclosed!`.
4. Fill beams are added for a long composite deck. `populate_levels!` builds
   the framing hierarchy (joists). `_record_deck_spans!` runs.
5. `estimate_column_sizes!` writes the **column seed**, `column.c1/c2`.
6. Column shape is set to `:circular` for circular RC on flat floors.
7. `ordinary_wall_result`, `stage_diagnostics` and `frame_section_floors`
   are cleared. With a lateral system, `prepare_lateral_model!` runs.
8. `to_asap!` builds the frame and shell model, processes it and solves it.
   This is the **first factorization**. Frame sections are placeholders and
   member self-weight is absent.
9. `snapshot!`.

Supports are not split at prepare. `initialize_supports!` runs at the
foundation stage (`SY/workflow/capture_results.jl::_size_foundations!` :18).
[read]

### 2.3 The stage graph

`SY/workflow/graph_builder.jl::build_design_graph` (:68) wraps the closures
from `SY/workflow/pipeline_spec.jl::build_pipeline` (:61) in `StageNode`s.
[read]

| Level | Node(s) | needs_sync | Function |
|---|---|---|---|
| 1 | `:slab_sizing_s{i}`, one per slab, in `eachindex` order (no shared flat-plate column) | true | `_make_slab_node_fn` → `design_floor!` → `install_floor_design!` (installs columns) |
| 1 | `:slab_propose_s{i}` (shared columns) | false | `_isolated_floor_outcome` on a private copy |
| 2 | `:slab_column_envelope` | false | `_apply_support_envelope!` |
| 3 | `:slab_sizing_s{i}` (commit) | false | `_commit_floor!` (`install_supports = false`) |
| 4 | `:slab_column_lock` | **true** | `settle!` over envelope + redesign |
| next | `:members` | `!flat` | `_design_flat_plate_members!` or `_size_beams_columns!`. An all-flat `:two_way` request is rerouted by `_member_stage_after_floor_resolution` (:313) |
| next | `:ordinary_walls` | false | `_walls_with_member_recheck!` (pipeline_spec.jl :169) |
| last | `:foundations` (optional) | false | `_size_foundations!` (capture_results.jl :18) |

The shared-column path is chosen by `_flat_plate_slabs_share_columns`
(graph_builder.jl :444). The barrier sync after a level uses
`loads_only = true` when `_stiffness_token` did not change across the level
(`SY/analyze/asap/asap/model_sync.jl::_loads_only_sync` :80). Slab nodes
change `column.c1/c2` but not the frame sections, so the slab barrier sync
reuses the prepare factorization. [inferred from the token contents, :19-66]

### 2.4 Member stage, flat plate

`_design_flat_plate_members!` (graph_builder.jl :372) [read]:

1. `_reconcile_columns!` (`SY/workflow/column_reconciliation.jl` :266):
   - `_install_sized_column_frame!` (:208) puts each RC column's concrete
     section and self-weight on the frame, then **always re-solves**
     (values-only K update, then `_refresh_pattern_solve_cache!`).
   - Axial growth: Ag at ACI 318-11 Eq. (10-2) with ρg = 0.01 from the frame
     Pu (`_column_asap_Pu`), then `grow_column_for_axial!` (max), then
     `_assign_flat_plate_column_section!`. If any column grew, the model is
     re-solved again.
   - `check_flat_plate_columns!` (`flat_plate_column_check.jl` :993) runs
     `settle!`: build the checks (`flat_plate_column_checks` :349, with
     slab-reported joint moments, or frame envelopes for columns no slab
     reports), then `_fit_flat_plate_columns!`. If any section changed,
     `update_structural_offsets!` and `_resolve_after_column_change!` run.
2. `_harmonize_columns!`. This does nothing unless `uniform_column_sizing`
   is on.
3. Settle loop, budget `monotone_budget(max_iterations, 48)` = 48 by
   default. Each round:
   - Slabs whose `designed_supports`/`designed_above` stamps differ from the
     installed columns are redesigned on isolated copies and committed
     without writing columns.
   - `_apply_support_envelope!` adopts any growth (grow-only gate
     `_support_beats`).
   - `_raise_column_floors!`.
   - `sync_asap!` (full).
   - `_reconcile_columns!(…; floors)`.
   - harmonize.

   The loop ends when no slab is stale. Running out of rounds **throws**
   (:408).

### 2.5 Member stage, beam floors

`SY/workflow/member_iteration.jl::_size_beams_columns!` (:210) [read]:

- If every slab is flat, flat-slab, grade or roof, it delegates to
  `_design_flat_plate_members!` (:241).
- With no beam edges, it runs the columns-only loop (L10, :279-291).
- If no story is designed by the story shell, it runs
  `_iterate_beams_columns!` (L9). Otherwise it runs `_size_with_story_shell!`
  (L11), which calls L9 inside.
- Non-convergence is written to `stage_diagnostics[:members]`
  (`_record_member_convergence!`).

One pass of L9:

1. `size_beams!`. It re-solves between framing levels
   (`SY/analyze/members/members/size_beams.jl` :182-188).
2. Rib and solid-head steps.
3. Fire coating sync, then `update_analysis!(:stiffness)`. This is a full
   `Asap.update!`, a solve and a pattern refresh.
4. `size_columns!`, harmonize, fire coating, then `update_analysis!(:stiffness)`.
5. The loop holds when no beam or column section changed. If a state
   repeats, `_check_settle!` runs.

After the member node, the level barrier runs `sync_asap!` (needs_sync =
`!flat`).

### 2.6 Walls ⇄ members, foundations, capture

- `_walls_with_member_recheck!` (pipeline_spec.jl :169, `max_rounds = 4`)
  [read]. Each round:
  1. `design_ordinary_walls!` (`SY/analyze/lateral/ordinary_wall_stage.jl`
     :164). This is a `settle!` over thickness jumps, budget
     `_wall_thickness_pass_cap(grouping) + 1` = 7 for `:pier` and 3 for
     `:all` (`SY/analyze/lateral/wall_thickness_jump.jl` :178). Each jump
     calls `apply_wall_thickness!` → `update_analysis!(:geometry)`, which
     rebuilds with `to_asap!`, restores the sized frame, and runs a full
     `sync_asap!` (model_sync.jl :335-396).
  2. `_floor_overstressed_frame_columns!`. RC frame columns that are not
     supported by a flat plate and fail P-M on the wall solution get a
     `frame_section_floors` entry.
  3. The round returns if the thicknesses, the floors and the overstress
     flag are all unchanged.
  4. Otherwise `size_members!` runs, followed by `sync_asap!` on the beam
     path. The round returns if no member section changed. Running out of
     rounds writes `stage_diagnostics[:wall_members]`.
- `_size_foundations!` runs `initialize_supports!`, then
  `size_foundations!(struc; …)`, which is strategy-aware. Its bearing check
  runs one extra unfactored D + L solve on the cached factor
  (`SY/analyze/foundations/demands.jl` :62). Nothing is fed back. [read]
- `capture_design` (execute.jl :20) deep-copies the structure and params,
  fills the result tables, and sets
  `converged = all_ok && isempty(stage_diagnostics)`. [read]

---

## 3. Loops

Growth rules: `grow-only`, `free`, `free+guard`. "Ratchet" means an earlier
size can outlive its reason within the run.

| id | Status | Anchor | Iterates | Budget | Growth | Converges when | Writes | Ratchet |
|---|---|---|---|---|---|---|---|---|
| L0 | **changed** (seed clamped; default `:axial`, see §1.2) | `SY/analyze/members/members/size_columns.jl::estimate_column_sizes!` | column.c1 = c2 seed (single pass) | — | sets the start | — | column.c1, column.c2 | **reduced**: the flat-plate fit (L6) can now go below the seed when punching demands are stored and uniform sizing is off [read]. Beam-path columns never read c1 for sizing (MIP picks sections) [inferred] |
| L1 | unchanged | `SY/workflow/graph_builder.jl::_make_slab_node_fn` | one slab design per slab, `eachindex` order | slab kernel `max_iterations` | slab kernel grows columns (`column_updates.jl::_update_column_sizes!` max) | single sweep | slab.*, cells, column.c1/c2/section via `install_floor_design!` (replace with the proposal) | within the slab stage, yes. L6 can undo it, but a slab redesign re-grows it and sets a floor |
| L2 | unchanged | `graph_builder.jl::_push_two_level_slab_nodes!` (propose, envelope, commit) | proposals on private copies, then per-column envelope | 1 propose + ≤ 1 commit per slab | grow-only (`_support_beats`) | — | column.c1/c2/shape/section | slab level yes; later relaxable by L6 |
| L3 | unchanged | `graph_builder.jl::_push_two_level_slab_nodes!` lock (`settle!`) | envelope + redesign of slabs whose supports moved | `monotone_budget(max_iterations, 48)` = 48 | grow-only | a round enlarges nothing; otherwise **throws** | columns, slabs | as L2 |
| L4 | **changed** (reconcile first; floors memory) | `graph_builder.jl::_design_flat_plate_members!` | stale-slab redesign → envelope → floors → sync → reconcile (+L5, L6) → harmonize | 48 | **free+guard**: columns can shrink in L6; slab redesign re-growth is kept as a floor | no slab stale; otherwise **throws** | slabs, cells, columns, floors (local) | yes, through `floors`: a size the slab kernel re-grew is never searched under again in this call |
| L5 | changed role | `SY/workflow/column_reconciliation.jl::_reconcile_columns!` | one pass of axial growth at ρg = 0.01 | — | grow-only (`grow_column_for_axial!`) | — | column.c1/c2/section, frame section | **no longer final**: L6 runs right after and can go below it [read] |
| L6 | **changed** (two-sided fit replaces grow) | `SY/workflow/flat_plate_column_check.jl::check_flat_plate_columns!`, `_fit_flat_plate_columns!` | per column: lightest catalog plan size passing P-M, §10.12, punching, cap | `monotone_budget(max_iterations, length(catalog))` (≤ 48 unless max_iterations is larger) | **free+guard** when `uniform_column_sizing === :off` and punching demand known; grow-only otherwise | a round changes no section; otherwise `stage_diagnostics[:flat_plate_columns]` | column.c1/c2/section/volumes, frame section | only through `floors` and through grow-only fallbacks |
| L6a | unchanged | `flat_plate_column_check.jl::_flat_plate_joint_moments` | max over slabs of joint moments | — | — | — | demand | demand envelope (not a size ratchet) |
| L7 | **removed** | `flat_plate_column_check.jl::_stack_flat_plate_columns!` (dead) | — | — | — | — | — | — |
| L8 | unchanged (now also switches L6 to grow-only) | `SY/workflow/member_iteration.jl::harmonize_uniform_column_sizes!` | group max c1, max c2 (RC) / largest area (steel) | single pass per call | grow-only | — | columns | yes when on; and with it on, L6 does not shrink (:927) |
| L9 | **changed** (cycle settle, rib/head steps) | `member_iteration.jl::_iterate_beams_columns!` | beams then columns, each followed by a stiffness re-analysis | `max_iterations` = 20 | free (MIP re-picks); `upward_only` floor on shell path | no section changed, or repeated state → `_check_settle!` | beam/column sections; rib pieces and solid heads (raise only) | rib/head steps and frame floors are grow-only [read docstrings] |
| L9b | **new** | `SY/workflow/check_settle.jl::_check_settle!` | install each cycle state, check all groups; mix; resize failures | n states + 1 mix + 3 resize rounds | free (picks cheapest passing) | a state or mix passes every group; otherwise false → `stage_diagnostics[:members]` | sections | no; it picks the cheapest passing state |
| L10 | unchanged | `member_iteration.jl::_size_beams_columns!` (no-beam-edges branch) | column MIP + stiffness | `max_iterations` | free | no section changed | column sections | no |
| L11 | **changed** | `member_iteration.jl::_size_with_story_shell!` | shell beam sizing → L9 with shell demands | 3 rounds, but **1** when checkable | `upward_only` floor (only for non-checkable options after round 1) | shell + service converged, beams and columns held | beam/column sections, slab design_details `converged` | yes for non-checkable options (floor after round 1) |
| L11b | **new** | `check_settle.jl::_reconcile_shell_frame!` | shell on installed sections → resize failing groups only | 4 attempts | free+guard (passing groups kept) | shell and frame both pass; stops on repeated state | beam/column sections | partial: a passing group keeps its section even if a lighter one would pass now [inferred] |
| L12 | unchanged (walls area) | `SY/analyze/lateral/ordinary_wall_stage.jl::design_ordinary_walls!` | per-group thickness jump + remesh | cap + 1 (7 for `:pier`, 3 for `:all`) | grow-only | no group grows | wall.t, ρ, `frame_section_floors` | yes |
| L13 | unchanged | `SY/workflow/pipeline_spec.jl::_walls_with_member_recheck!` | L12 then the whole member stage | 4 rounds | walls grow-only; members follow L4 or L9 | thickness, floors and overstress unchanged, or members held | everything the member stage writes | wall thickness and frame floors persist; **flat-plate columns can now shrink on a rerun**, because `floors` resets per member-stage call [read] |
| L14 | unchanged | `SY/design_graph/executor.jl::execute_graph!` / `scheduler.jl::run_target!` barrier → `sync_asap!` | — | once per synced level | — | — | cells self-weight, pressures, member self-weight, coating | — |
| L15 | unchanged (not on `design_building`) | `SY/core/size.jl::size!` | beams/columns | 3 | free | Pu change < 5% | sections | no |
| L16 | unchanged (unreachable end-to-end) | `SY/core/snapshot.jl::_adopt_larger_column!` | max-merge on partial slab overlay | — | grow-only | — | columns | guarded unreachable (scheduler.jl :480-490, :620-627) |
| L17 | **new name for an existing pass** | `pipeline_spec.jl::_floor_overstressed_frame_columns!` | floor RC frame columns failing P-M on the wall solution | per L13 round | grow-only (objective max) | — | `frame_section_floors` | yes |

Notes:

- **L4 termination with a two-sided L6.** [inferred] A shrink in L6 makes
  the adjoining slabs stale (stamp mismatch). Their redesign either accepts
  the smaller column or grows it back through the envelope, and
  `_raise_column_floors!` then pins that size. Floors only rise, so each
  column can bounce down at most a bounded number of times. Exhausting the
  48 rounds still throws.
- **L6 inside L4.** `_reconcile_columns!` re-grows every column to the
  ρg = 0.01 axial footprint before each fit. L6 can then shrink it back, so
  in steady state each L4 round can spend an extra re-solve on this
  round trip (§6).
- **Order dependence.** L6 visits columns in sorted order. All checks come
  from one solve per round, and punching uses stored slab demands, so the
  order within a round does not matter. [read]

---

## 4. Writers

### 4.1 Column plan size and section at building level

The baseline listed seven grow-only writers: seed, slab envelope, reconcile,
full-load check, stacking, harmonize, and row-F floors. Today:

| # | Writer | Anchor | Rule | Relaxes now? |
|---|---|---|---|---|
| 1 | Seed | `SY/analyze/members/members/size_columns.jl::estimate_column_sizes!` | replace: square c = max(axial at ρg = 0.01 × floors above, 14") for `:axial`, then `min(c, max_column_size)` | The value itself is unchanged, but it is **no longer a floor** for flat-plate columns with stored punching demand when uniform sizing is off. L6 searches from zero up to the `floors` entry. [read] |
| 2a | Slab kernel (sequential path) | `SY/floor_design_contracts.jl::install_floor_design!` (`install_supports = true`), from `SS/.../column_updates.jl::_update_column_sizes!` | kernel: `max(c_span_min, c_pm, c_old)`; install: replace | No inside the slab stage. Yes afterwards, through L6. |
| 2b | Slab envelope (shared / L4) | `SY/workflow/graph_builder.jl::_apply_support_envelope!` → `_install_governing_support!` | replace only if ≥ current in both c1 and c2 (`_support_beats`); ties by area, then Ast, then lowest slab | Grow-only. Its growth inside L4 is also recorded by #6. |
| 3 | Axial reconcile | `SY/workflow/column_reconciliation.jl::_reconcile_columns!` (`grow_column_for_axial!`, `_assign_flat_plate_column_section!`) | max | Transient: L6 runs next and can go under it. [read] |
| 4 | Full-load fit | `SY/workflow/flat_plate_column_check.jl::_fit_flat_plate_columns!` | replace with the lightest passing section; lower bound = `floors[i]` (shrink mode) or max(current, floors[i]) (grow mode) | **Yes**: two-sided when `uniform_column_sizing === :off` and `_column_punching_demands` is non-empty. A column with no stored punching analysis is grow-only. |
| 5 | Stacking | `flat_plate_column_check.jl::_stack_flat_plate_columns!` | — | **Removed** (no caller). |
| 6 | Floors memory | `graph_builder.jl::_raise_column_floors!` | `floors[i] = max(floors[i], c)` when a slab redesign grew the column | Guard. Grow-only within one member-stage call; reset on the next call (L13 rerun). |
| 7 | Harmonize | `SY/workflow/member_iteration.jl::_harmonize_rc_group!`, `_harmonize_steel_group!` | max c1 and max c2 independently (RC); largest area (steel) | Grow-only. When on, it also switches #4 to grow-only. |
| 8 | Row-F frame floors | `SY/analyze/lateral/interactive_checks.jl` (:919) | catalog floor (mask) | Grow-only, kept for the run. Read by `size_columns!` and `size_beams!` only; the flat-plate fit does not read it (see §7). |
| 9 | Overstress floors | `SY/workflow/pipeline_spec.jl::_floor_overstressed_frame_columns!` | `frame_section_floors[gid] = sec` when its objective is above the previous floor | Grow-only. Non-flat RC frame columns only. |
| 10 | Beam-path column MIP | `SY/analyze/members/members/size_columns.jl::size_columns!` | replace (fresh MIP each pass), masked by #8/#9 and by the shell `section_floor` | Free, apart from floors. |
| 11 | Check-settle install | `SY/workflow/check_settle.jl::_install_member_section!` / `_install_state!` | replace with a cycle state or mix; also writes c1/c2 from the RC bounding box | Free (cheapest passing). |
| 12 | Shell reconcile | `check_settle.jl::_resize_rejected!`, `_restore_passing_columns!` | re-pick failing groups; put passing groups back | Free+guard. |
| 13 | Scheduler overlay | `SY/core/snapshot.jl::_adopt_larger_column!` | max-merge | Unreachable end-to-end. |
| 14 | Restore / capture | `SY/core/snapshot.jl::restore!`, `capture_node_state` | replace (pristine / copy) | n/a |

Of the baseline's seven grow-only writers, two now relax: the seed (no
longer binding) and the full-load check (now a two-sided fit). The axial
reconcile still grows, but its growth no longer survives on its own.
Stacking is gone. The envelope, harmonize and the row-F floors are still
grow-only. One new grow-only writer, `floors` (#6), deliberately pins slab
re-growth.

### 4.2 Other building-level variables

| Variable | Writers |
|---|---|
| slab.result, design_details, drop_panel | `install_floor_design!` (replace); `_commit_floor!`. The stamps `designed_supports` and `designed_above` are written at install. [read] |
| cell.self_weight, live_load | `install_floor_design!` (from the proposal); `sync_asap!` (self_weight from slab.result, model_sync.jl :124-129) |
| beam.section | `size_beams!` (replace, masked by floors); rib and head steps (raise); `_install_state!`; `_resize_rejected!` |
| wall.t | `apply_wall_thickness!` (grow-only) |
| `frame_section_floors` | `interactive_checks.jl`, `_floor_overstressed_frame_columns!`; emptied at `prepare!` |
| `stage_diagnostics` | `check_flat_plate_columns!` (:flat_plate_columns), `_record_member_convergence!` (:members), `design_ordinary_walls!` (:walls), `_walls_with_member_recheck!` (:wall_members); emptied at `prepare!` |
| asap_model | `to_asap!`, `sync_asap!`, `_resolve_after_column_change!`, `_reanalyze_after_section_change!`, `update_analysis!(:geometry)` |

---

## 5. Fast-tier inventory (F.1)

| Element | Where the analysis is chosen | Embedded in the designer? | Checks that are pure f(geometry, size, demands) | What a fast demand source needs | What blocks separating analysis from design |
|---|---|---|---|---|---|
| Flat plate / flat slab | Floor options method (DDM/EFM/FEA) inside the SS kernel via `design_floor` (`SY/floor_design_contracts.jl::design_floor` → `SS.design_floor`). The pipeline only supplies `FlatPlateDesignInput` (a deep copy of the whole topology, cells, all supports and slabs). [read] | Yes. Analysis, punching, column growth and thickness iterate inside one kernel call. | At the pipeline level: `_punching_passes` (punching at a trial c1×c2 from stored Vu/Mub/Muy, h, d, f′c) and `_rc_section_check` (P-M at a section from stored demands) are pure. [read] | Per column Vu, Mub, Muy and Pu per slab, with a known dependence on c1×c2 (the stored moment is taken as conservative for smaller columns) | The kernel couples h, columns and punching. Column stamps make any column change a full redesign. `FlatPlateDesignInput` copies the building per call. |
| Flat-plate columns (full load) | Frame `asap_model` for Pu (`_column_asap_Pu`); slab-reported joint moments; frame envelopes for columns no slab reports | No. `check_flat_plate_columns!` reads stored demands, then re-solves between rounds. | `_fit_flat_plate_columns!` is a pure search given (Pu, M1/M2, joint entries, punching demands, geometry, catalog), apart from the re-solve after a change | Pu per column that tracks column self-weight; joint moments that do not need a slab redesign | Pu depends on the column self-weight installed on the frame, so each change needs a re-solve. P-M caches are built per settle round. |
| Beams / columns (beam floors) | `member_group_demands` on `asap_model` plus the pattern cache; shell demands on story-shell levels | Partly. `size_beams!` and `size_columns!` take demands, but `size_beams!` re-solves between framing passes and the pipeline re-solves between halves. | Pinned group checks in `_beam_group_report` and `_column_group_report` (check_settle.jl) are pure given demands | Group demands per state, and stiffness sensitivity | Beam ⇄ column stiffness coupling; story-shell demands depend on sections; check-settle installs and re-analyzes every candidate state |
| Walls | `design_ordinary_walls!` runs gravity basic cases, wind, ELF and second-order story stiffness on the current mesh | Yes. The analysis is run per pass inside the stage. | The thickness proposal `propose_wall_thicknesses` works from trials (walls area) | Per-pier actions as a function of t | A thickness change remeshes (`to_asap!`), so every jump is a full rebuild |
| Foundations | Reactions of the last mutating solve, plus one unfactored D + L solve (`SY/analyze/foundations/demands.jl` :62) | No (read-only) | Footing sizing given reactions (foundations area) | Reactions per combination | None at the pipeline level; it is a one-way consumer |

---

## 6. Size-impact and speed findings

### 6.1 Where full building analyses happen

Terms used below:

- A **factorization** is any call that rebuilds K and solves: `to_asap!`,
  `Asap.update!` (full or values-only) followed by `_solve_struc_model!`, or
  `Asap.process!` followed by a solve.
- A **loads-only solve** reuses the cached factor.
- A **pattern refresh** is a multi-RHS `Asap.solve(model, cases, links)` on
  the current factor (`SY/analyze/asap/asap/pattern_cases.jl::_refresh_pattern_solve_cache!`
  :65). It applies only when pattern cases exist.

| Stage / step | Anchor | Factorizations | Count per round |
|---|---|---|---|
| Prepare | `SY/workflow/prepare.jl::prepare!` → `to_asap!` (`model_builder.jl` :610-620) | 1 | once per design |
| Slab barrier sync (sequential slab level, or lock) | `executor.jl` :49 / `scheduler.jl` :658 → `sync_asap!` | 0 when the K token is unchanged (loads-only + patterns), else 1 | once per design (1 slab level) |
| Flat members, before the loop | `_reconcile_columns!`: `_install_sized_column_frame!` (always 1), axial grow (+1 if any grew), `check_flat_plate_columns!` (+1 per round that changes a section, ≥ 1 round of checks); harmonize (+1 if it changed anything) | 1 to (3 + rounds) | once |
| Flat members, per L4 round | `sync_asap!` (full, 1) + the same reconcile set as above | about 3 to 5 typical; up to 2 + L6 budget | ≤ 48 rounds (throws after) |
| Beam members, per L9 pass | `size_beams!` re-solves between framing passes (`size_beams.jl` :182-188); `raise_head_face_ribs!` can solve (`rib_variation.jl` :79-82); `update_analysis!(:stiffness)` ×2 (`member_iteration.jl` :374, :380) | ≥ 2 (+ framing passes − 1, + rib solve) | ≤ 20 passes |
| Check-settle | `_install_state!` (1 per cycle state), the mix (1), `_resize_failures!` (1-2 per attempt, ×3) | n_cycle + 1 + ≤ 6 | once per cycle hit |
| Story-shell reconcile | `_resize_rejected!` (re-analysis per beam framing pass + 1) plus story-shell solves | ≤ 4 attempts × (1-3) | once |
| Columns-only loop (L10) | `update_analysis!(:stiffness)` | 1 | ≤ 20 passes |
| After members (beam path) | level barrier `sync_asap!` | 1 (K changed) | once per member-stage run |
| Walls, per jump pass | analysis: gravity basic cases, wind, ELF (multi-RHS), second-order story stiffness (one factorization per distinct factored gravity; `ordinary_wall_stage.jl` :952-996); jump: `update_analysis!(:geometry)` = `to_asap!` (1) + `sync_asap!` (1) | about 2 + K_G count | ≤ 7 passes (`:pier`) |
| Walls ⇄ members | the whole member stage + `sync_asap!` (beam path) | the member-stage total | ≤ 4 rounds |
| Foundations | `demands.jl` :62 `Asap.solve` on the cached factor | 0 | once |
| Capture | none (deep copy) | 0 | once |

Worst case, by multiplication [inferred]: walls ⇄ members (4) × flat
member stage (48 × ~5) is about 1,000 factorizations. Typical runs settle in
1-2 L4 rounds and one recheck round.

### 6.2 Ranked findings

**Size**

1. **The slab kernel's greedy column growth is pinned by `floors`.**
   [read + inferred] `_fit_flat_plate_columns!` can now pick a smaller column
   than the slab grew. That makes the slab stale, so it is redesigned at the
   smaller column. The SS kernel restarts h from its minimum and, with the
   default `:grow_columns` punching strategy, grows the column before h.
   `_raise_column_floors!` then records that size as a floor for the rest of
   the member stage. The kernel's first-failure choice (grow columns at thin
   h) is therefore still the effective lower bound, now per column rather
   than per seed. This is the main remaining ratchet on flat-plate columns.
   Fix direction: a joint (h, c) search (`:joint_search`) in the kernel, or
   do not record a floor when the regrowth happened at a thinner h than the
   final one.
2. **Grow-only modes still disable the new relaxation.** [read]
   `shrink = params.uniform_column_sizing === :off` (:927). With harmonize
   on, every L6 search is floored at the current size, and harmonize keeps
   the independent per-dimension max (baseline L8). Columns with no stored
   punching analysis (`known = false`, :933-938) are also grow-only, which
   includes core and frame columns that no slab reports.
3. **Section floors and wall thickness persist across recheck rounds.**
   [read] These are row-F floors, overstress floors (both grow-only,
   objective-sorted), and the story-shell `upward_only` floor on
   non-checkable options. `_walls_with_member_recheck!` reruns the members
   with all of them still in place, and wall thickness never comes back
   down. This is unchanged from the baseline (items 10 and 6).
4. **The shared-column envelope picks the largest single-slab proposal.**
   [read] This is unchanged (L2/L3). L6 can now go under it if punching
   passes at the stored demand, but any regrowth is pinned by finding 1.
5. **Stacking removed.** [read] Lower columns can now be smaller than the
   columns above. This is a size reduction. It is also a constructability
   and policy change that nothing reports except the `nonmonotone` count in
   the trace.

**Speed**

1. **The flat-plate member stage (L4) does redundant re-solves.** [read]
   `_install_sized_column_frame!` re-solves on every `_reconcile_columns!`
   call, even when nothing changed (column_reconciliation.jl :208-220,
   :284). The axial growth at ρg = 0.01 (:292-305) is re-applied before every
   fit, and L6 then undoes it. That round trip costs up to 2 more
   factorizations per call even at a fixed point [inferred]. The P-M catalog
   cache in `_fit_flat_plate_columns!` (`caches`, :924, :941-945) is local
   to one settle round, so it is rebuilt every round. Each stale-slab
   redesign builds `FlatPlateDesignInput`, which deep-copies the whole
   building's topology, cells and supports (floor_design_contracts.jl :33-97).
   Fix direction: skip the frame-install solve when the sections are
   unchanged, drop or defer the axial growth now that the fit sizes axial,
   hoist caches per material, and build the input once per level.
2. **Walls ⇄ members multiplies everything.** [read] There are up to 4
   rounds, each with a full member stage and up to 7 wall analyses. Each
   wall jump does a `to_asap!` rebuild plus a full `sync_asap!`. This is
   unchanged from the baseline.
3. **The beam ⇄ column loop and check-settle.** [read] Each pass makes 2 or
   more full K rebuilds (`_reanalyze_after_section_change!` uses a full
   `Asap.update!`, not values-only, member_iteration.jl :174-185). Each
   check-settle state re-analyzes and re-runs the pinned group checks at
   `resolution = 200`. Cycle detection bounds the loop, so 2-cycles no
   longer spend all 20 passes.
4. **Scheduler overhead on the default path.** [read]
   - `DesignSession` makes whole-structure deep copies: three in
     `prepare_engine`, one more in `run_target!`, one per dirty level
     (4 levels sequential, 7 two-level, in `:shared` mode), and one in
     `capture_design`.
   - It builds the graph twice (`prepare_engine` :253 and `run_target!` :452).
     Each build runs `prepare_floor_design_workspace`, a P-M precompute.
   - It computes `output_hash` for every dirty node. A slab node writes
     `[:slabs, :columns, :cells, :asap_model]`, so each of the n slab nodes
     hashes every frame element's forces, `u`, `reactions` and `repr` of
     every slab's design details (fingerprint.jl :144-194, provenance.jl
     :172). That is O(n_slabs × model size) per run. [inferred cost]
   - None of this is needed for a one-shot design.

### 6.3 Trace coverage

[read]

- On the default (session) path, `design_building` emits no
  `:pipeline/design_building` enter/exit/failure. Those events appear only
  in `_design_building_inplace` (execute.jl :150-207).
- `build_pipeline` enter/decision/exit is emitted twice per session run,
  because the graph is built twice.
- `sync_asap!` and `_resolve_after_column_change!` emit nothing.
  `update_analysis!` emits a `:workflow/update_analysis!` decision.
- `_raise_column_floors!` and each L4 round emit nothing; only the final
  `_design_flat_plate_members!` decision (passes, stop) is emitted.
- `_walls_with_member_recheck!`, `_size_beams_columns!` and `size_foundations!`
  emit events but are not in `TRACE_REGISTRY`. The registry entries in this
  area are `design_building`, `design_building_kwargs`, `build_pipeline`,
  `run_pre_sizing_validation`, `_design_flat_plate_members!`,
  `_reconcile_columns!`, `check_flat_plate_columns!` and `_resolve_strategy`.

---

## 7. Open questions

1. **Is the stored punching demand conservative at a smaller trial column?**
   `_fit_flat_plate_columns!` checks punching at a trial c1×c2 using `Vu`
   and `Mub` stored from the analysis at the installed size. The docstring
   argues the stored moment is the heavier demand (:906-911). But `Vu` net of
   the load inside the critical section rises slightly as the column
   shrinks. Whether `column_shears` is gross or net is a slabs-area
   question. The slab redesign triggered by the stamp mismatch rechecks
   punching at the installed size, so the final state is checked
   [inferred]. The intermediate choice may still be optimistic. This needs
   sign-off per `code-accuracy.mdc`.
2. **Does the flat-plate member stage need to honor `frame_section_floors`?**
   Row F (`interactive_checks.jl` :919) can floor a frame group. The
   flat-plate fit does not read the mask, and `_floor_overstressed_frame_columns!`
   skips flat-supported columns. A row-F floor on a flat-plate column group
   would end L13 as "members held" without being applied. [inferred]
3. **The L6 budget is `monotone_budget(...)` on a loop that is no longer
   monotone.** Should it have a cycle guard like L9's `history`, or is the
   `stage_diagnostics` fallback enough?
4. **Is the removal of stacking intended as policy?** Some offices treat
   lower ≥ upper as a constructability rule. It is not a code requirement.
   The dead `_stack_flat_plate_columns!` and `_grow_flat_plate_columns!` can
   be deleted once this is confirmed.
5. **Should floors survive a walls ⇄ members rerun?** `floors` resets every
   time `_design_flat_plate_members!` is called, so a rerun on a stiffer
   model can shrink columns again and redesign slabs. That is good for size
   and costly for speed.
6. **`apply_wall_thickness!` writes `params.wall_thickness`**
   (`wall_thickness_jump.jl` :811, :838). On the session path the engine
   holds `context.params`. A jump mutates the params the scheduler hashes
   (`PREPARE_AFFECTING_FIELDS` includes `:wall_thickness`), so a later
   `redesign` on the same session may see a changed prepare-affecting field.
   [inferred]
7. **Can the column fit run on FEA-analyzed flat plates?**
   `_column_punching_demands` needs `moment_results.column_shears` and
   `unbalanced_moments` aligned with `find_supporting_columns`. If FEA
   results do not populate these, those columns stay grow-only. This is a
   slabs-area question.
8. **Is the seed still needed?** With L6 two-sided, the seed only affects
   slab-stage clear spans and the first slab design. A smaller seed would
   speed nothing up and would change the slab kernel's starting h only.
   Worth a size comparison before removal.

Files not fully read: `SY/workflow/capture_results.jl` (only the
foundation entry and the helpers at the top),
`SY/analyze/lateral/ordinary_wall_stage.jl` beyond the stage driver, and the
story-shell internals (`size_beams_story_shell.jl`, `story_shell*.jl`). All
of these belong to other areas. No file in scope was uninterpretable.
