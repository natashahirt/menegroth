# Sizing map — walls, lateral system, foundations, analysis-resize loops

Scope: ordinary/shear walls, lateral system / drift / P-Delta, foundations (spread, combined, mat, pile, grouping),
analysis-resize loops (sync_asap!, update_structural_offsets!, self-weight, load re-derivation), outer whole-building iteration.
Read-only mapping; line numbers are as of 2026-11-11 working tree. Paths abbreviated:
`SSz/` = `StructuralSizer/src/`, `SSy/` = `StructuralSynthesizer/src/`.

(Complete. Part B loop records first, then Part A decision space, then the top-5 list at the end.)

## Pipeline skeleton (context)

`build_pipeline` (SSy/workflow/pipeline_spec.jl:61) composes stages: (1) slabs `design_floors!` (needs_sync=true, :90-107);
(2) members — flat: `_design_flat_plate_members!`, else `_size_beams_columns!` (needs_sync = !flat, :113-122);
(3) walls `_walls_with_member_recheck!` (needs_sync=false, self-syncs, :131-133);
(4) foundations `_size_foundations!` (needs_sync=false, read-only on model, :135-142).
Outer executor: `stage.fn(struc); stage.needs_sync && sync_asap!(struc; params)` (SSy/workflow/execute.jl:15 docstring; graph executor
SSy/design_graph/executor.jl:48 syncs once per level). There is **no outer whole-building fixed-point loop** over stages 1→4: slabs are
never re-sized after walls/members change, and foundations run exactly once at the end. The only cross-stage feedback is
walls ⇄ members inside stage 3.

---

## Part B — loop records

### settle! (generic monotone driver)
- location: SSz/iteration.jl:56-63, `settle!`; budgets `monotone_budget` :35-43, `growth_steps` :18-23
- decision variables: none itself; drives a caller `step!(k)::Bool`
- inputs / outputs: caller closure; returns `(converged, steps, stop ∈ {:settled,:budget})`
- stop rule + budget + step size: stops at first pass returning `false`; `budget` passes max. `monotone_budget(requested, span; ceiling=48)` = max(requested, min(span, 48)).
- monotone? Not enforced here — relies on caller (docstring :5-8 assumes grow-only fixed increment).
- order dependence: none intrinsic.
- cost per pass: whatever the closure costs.
- size impact: LOW (driver only). Note: `stop=:budget` ⇒ "last analysis stands" in callers, so an un-settled design can ship with failing checks rather than over-size.
- speed impact: LOW
- opportunities: expose per-step "growth amount" so callers can detect oscillation/no-progress early.
- confidence: verified-by-reading

### Ordinary-wall thickness jump loop
- location: SSy/analyze/lateral/ordinary_wall_stage.jl:147-176, `design_ordinary_walls!` (settle! closure :154-168); proposal SSy/analyze/lateral/wall_thickness_jump.jl:562-591 `propose_wall_thicknesses`, :426-463 `propose_wall_thickness`; apply :640-678 `apply_wall_thickness!`
- decision variables: `wall.thickness` per group (`params.wall_thickness_grouping` ∈ :all, :story, :wall_line, :pier_stack, :wall_line_story, :pier; default `:pier`, parameters.jl). ρl/ρt are re-picked from the §11.6.2 floor on every `select_ordinary_wall_reinforcement!` call. A grown wall is also reset to 0.0025 before that call.
- inputs / outputs: each pass = full lateral (`_analyze_lateral_walls!`, :180-429) or gravity (`_analyze_gravity_walls!`, :456-528) analysis → `OrdinaryWallResult` + `WallThicknessTrial`s (frozen demand per pier, :420-425, :680-685). Feeds: `struc.ordinary_wall_result`, wall thickness for foundations (pipeline_spec.jl:124-130), triggers member re-size in `_walls_with_member_recheck!`.
- stop rule + budget + step size: stops when no target grows >0.1 mm (`_thickness_grows`) or `params.jump_wall_thickness == false`. Budget = `_wall_thickness_pass_cap(grouping)+1` = 3 for `:all`, 7 otherwise. Step: 1 in grid. The thickness catalog starts at `wall_thickness_limit` (36 in). `:hard` errors when nothing in it passes or a §18.10.6.4 shortfall is past it. `:soft` (default) steps the limit by 12 in, warns, and errors at 72 in. Proposal picks the thinnest inch passing the frozen-demand proxy.
- monotone? Yes, grow-only: `propose_wall_thicknesses` starts from current thickness and only moves failing groups (:564-581); `apply_wall_thickness!` writes only growing walls (:668-673); `_raise_boundary_thickness!` only raises (:616). On budget exhaustion the jump is not applied on the last pass (`pass < budget || return true`, ordinary_wall_stage.jl:164) → diagnostic `:walls` (:171-174).
- order dependence: groups proposed independently from the same analysis (no intra-pass order effect). Across passes, forces redistribute toward stiffened groups (documented :62-70).
- cost per pass: one `to_asap!` rebuild + restore + `sync_asap!` (via `update_analysis!(:geometry)`, model_sync.jl:347-350, 379-396), then the analysis: gravity basic cases, wind + ELF story analyses, and **one extra full linear solve per distinct factored-gravity key with K_G** (`_build_second_order`, ordinary_wall_stage.jl:795-847, solve at :839). ≈ (1 rebuild + 1 sync solve + ~5–7 K_G solves × (3 + nwind + nQE) RHS) per pass.
- size impact: **HIGH**. Mechanisms: (a) drift and interactive story shear are building results handed to **every** group (`_group_needs_thickness`, :486-495; `_result_for_group` keeps drift, :515-532), and `_drift_scale` is the max over all stories/directions (:333-341) ⇒ a drift failure in one story/direction thickens every wall in every group by the same t0·max(drift/allow) — a uniform drift fix even with finer grouping; (b) the default grouping is `:pier`, so a local pier failure thickens that wall; `:all` still thickens every wall; (c) proxy treats drift ∝ 1/t (wall_thickness_jump.jl:371, 381) — conservative when frame/columns share stiffness or when only some walls grow; (d) grow-only: a pass-1 thickness driven by forces that later redistribute is never undone; (e) whole-inch ceil plus "not below geometric need" floors.
- speed impact: HIGH (each pass = remesh + ~several full FE solves with geometric stiffness; up to 7 passes for fine groupings).
- opportunities: compute drift sensitivity per group (virtual-work / ∂drift/∂t_g) instead of uniform scale; let drift drive only groups that participate in that story/direction; allow a final "shrink" sweep with re-analysis for groups whose utilisation < threshold; reuse factorization across K_G keys (K changes only by K_G — consider a low-rank/iterative update or a single K_G for close keys); run proxy-only passes until convergence and remesh once to confirm.
- confidence: verified-by-reading

### Ordinary-wall reinforcement (ρt then ρl grid walk)
- location: SSy/analyze/lateral/wall_ordinary_check.jl:374-410, `select_ordinary_wall_reinforcement!`; grid :218 (`0.0025:0.0005:0.0200`); `_rho_on_grid` :246-253; `_rho_l_floor` :282-290 (ACI 318-19 Eq. 11.6.2); called per pier from `_select_pier_steel!` ordinary_wall_stage.jl:594-604; row F raise `_enforce_interactive_wall_shear!` (ordinary_wall_stage.jl:367-368; see interactive_checks.jl:281 `while cap + 1.0 < target`).
- decision variables: `wall.ρt`, `wall.ρl` per pier.
- inputs / outputs: max |Vu| over all combos/cases of the pier (:390) → ρt from ACI 318-19 Eq. 11.5.4.3 (:221-230); ρl walks up from floor until in-plane flexure (`_flexure_passes!`) and out-of-plane (`_out_of_plane_passes`, :348-356) pass every action. Feeds the recorded checks.
- stop rule + budget + step size: first passing grid value; 0.0005 step; ceiling 0.02 (demand not coverable leaves wall at top of grid).
- monotone? No. `select_ordinary_wall_reinforcement!` ignores the ratios already on the wall and starts from 0.0025 / Eq. (11.6.2). Special shear and the row F story-shear bump run after that call and only raise. A grown wall is also reset to 0.0025 in `apply_wall_thickness!`.
- order dependence: each analysis re-derives ρ from the current demands. Special shear can raise the ordinary selection in the same pass, because Ωv depends on ρl.
- cost per pass: cheap (sectional checks), no FE.
- size impact: LOW after the reset. The remaining conservatism is the max |V| over actions, the 0.0005 grid, and special shear raising ρl because Ωv depends on it.
- speed impact: LOW
- opportunities: none on the ordinary ratio. The within-pass raise for special shear and row F stays, because those demands are applied after the ordinary selection.
- confidence: verified-by-reading (ratchet); row-F raise details inferred from call site.

### Walls ⇄ members recheck (stage 3 outer loop)
- location: SSy/workflow/pipeline_spec.jl:167-195, `_walls_with_member_recheck!`
- decision variables: wall thickness (via inner jump loop), member sections (beams/columns via `size_members!`), `struc.frame_section_floors` (row F frame section floors).
- inputs / outputs: runs `design_ordinary_walls!` → if thickness or frame floors changed, or an RC frame column fails P–M on that solution, re-runs the whole member stage (`_size_beams_columns!` or `_design_flat_plate_members!`) then `sync_asap!` when not flat. A failing frame column is floored at its current section first. Feeds foundations.
- stop rule + budget + step size: returns when walls and floors are unchanged and no frame column fails, or member sections are identical after re-size. `max_rounds=4` → `stage_diagnostics[:wall_members]`.
- monotone? Walls grow-only (above); frame floors "only move to a heavier catalog section" (docstring :161-162). Member re-size itself starts from current sections (whether members are grow-only is owned by member_iteration.jl — out of scope).
- order dependence: walls always first, members second; members are re-sized on the thickened-wall model so walls attract more lateral load ⇒ frame relief; but walls are not re-checked for thinning.
- cost per pass: one full wall stage (≥1 remesh + K_G solves) + one full member stage (its own iteration loop with FE solves) + sync.
- size impact: MED — wall thickness is fixed at its maximum from round 1 even after member changes; row F frame floors ratchet. Wall reinforcement is re-picked from the current demands on the next analysis.
- speed impact: HIGH (each round nests two iterative stages).
- opportunities: skip member re-size when wall stiffness change is below a threshold (members re-size only if member forces change > tol); pass a warm start; consolidate into one coupled fixed point with a single convergence test.
- confidence: verified-by-reading

### Story geometric-stiffness (P-Delta) solve set — not iterated
- location: SSy/analyze/lateral/ordinary_wall_stage.jl:795-847, `_build_second_order`; keys `_stage_gravity_keys` :752-768; K_G build SSy/analyze/lateral/story_pdelta.jl:59 `story_geometric_stiffness`, :106 `story_axial_profiles`; first-order variant for flexible floors :858-876 `_build_first_order`
- decision variables: none (analysis); feeds pier second-order actions `_second_order_*_actions` :894-925.
- inputs / outputs: unfactored D/L/roof displacements → per factored-gravity key (D,L,roof) a K_G from the story axial profile → one `Asap.solve(...; geometric_stiffness=Kg)` on the batch [D, L, roof, every wind case, every QE effect] (:839). Wilson & Habibullah 1987 Eq. 7 (docstring :113-117). Outputs second-order pier N/V/M used by both ρ selection and the recorded checks; ACI 318-19 §6.2.5.3 1.4× limit recorded (:1012-1028).
- stop rule + budget + step size: **single pass** — "the matrix is not iterated" (:785-786). K_G is from first-order factored gravity only.
- monotone? n/a
- order dependence: none.
- cost per pass: one factorization+solve per distinct gravity key (≈ 4–6 keys from the ASCE 7 strength combos incl. combo-3 split, :752-768) × (3 + nwind + nQE) RHS; repeated every thickness pass and every walls⇄members round. Plus equilibrium cut checks per key (:841-843).
- size impact: LOW on a rigid diaphragm (linearized P-Δ is in the story stiffness; drift amplification 1/(1−θ) is not applied to those forces again). On a flexible or semirigid floor the seismic member forces are multiplied by that same factor, once; gravity, wind, and Ev are not. Drift is not multiplied a second time.
- speed impact: HIGH (dominant per-pass FE cost of the wall stage).
- opportunities: reuse the elastic factorization and solve (K − K_G) by low-rank update since K_G only touches master DOFs (story_pdelta.jl:56-59 — 3 DOF per story); collapse keys whose (D,L,roof) differ by < tolerance; cache K_G across thickness passes when only wall thickness changed (profiles change via self-weight only).
- confidence: verified-by-reading

### Story drift / θ check (ASCE 7-22 §12.8.6–12.8.7)
- location: SSy/analyze/lateral/story_demands.jl:294-321, `_story_drift_with_pdelta`; orthogonal variant `_orthogonal_story_drift` (called :298); θmax gate `require_seismic_wall_demand_provisions` (ordinary_wall_stage.jl:295-307); ELF build `elf_story_analysis` SSy/analyze/lateral/elf_story_cases.jl (one `Asap.solve` with all ELF cases :242).
- decision variables: none directly; failures drive the thickness jump via `_drift_scale` (wall_thickness_jump.jl:333-341).
- inputs / outputs: design drift × 1/(1−θ) vs `allowable_story_drift(h, risk_category, system)`; per story × direction × torsion sign.
- stop rule + budget + step size: n/a (check). Period `T` is a caller input (elf_story_cases.jl:33-34), so stiffening walls does not change Cs. Seismic weight W is cell (self + SDL) only (SSy/walls/seismic_mass.jl:43-47) — wall and frame self-weight are not in W, so thickening walls does not raise ELF forces (no counter-productive feedback; note this omission is a potential **under**-estimate of W, ASCE 7-22 §12.7.2 — flag for the corpus owner, not a size-inflation issue).
- monotone? n/a
- order dependence: none.
- cost per pass: one multi-RHS solve for ELF cases + wind cases per thickness pass.
- size impact: HIGH via its consumer — the single worst story/direction ratio scales every wall group (see thickness-jump record).
- speed impact: MED
- opportunities: return per-story/per-direction drift ratios to the proposer and only thicken walls in that direction/story band (walls parallel to the failing axis carry the drift stiffness); use `story_drift_sensitivity` (SSz/walls/lateral/sensitivity.jl:15-) which already computes ∂drift/∂k_i analytically for a reduced diaphragm model — currently unused by StructuralSynthesizer (no references to `WallLayoutNLPProblem`/`story_drift_sensitivity` in SSy/).
- confidence: verified-by-reading (W composition, T input); orthogonal path inferred.

### Row F interactive wall shear raise (§12.2.5.8 75% rule)
- location: SSy/analyze/lateral/interactive_checks.jl:263-300 (`while cap + 1.0 < target`, :281), inside `_enforce_interactive_wall_shear!` (called ordinary_wall_stage.jl:367-368)
- decision variables: `wall.ρt` (then `_reraise_vertical_ratio!` re-picks ρl, :298-300)
- inputs / outputs: per level × direction, target = 0.75 V_story (ASCE 7-22 §12.2.5.8, :273-274); capacity Σ cosθ·φVn.
- stop rule + budget + step size: loop bumps **one wall per iteration** — the one with the lowest ρt (sort by (ρt, index), :283) — by one grid step (`_bump_rho_t!`); stops when capacity ≥ target or all walls stalled (:296).
- monotone? Yes (ρt only increases; persists through the ratchet in `select_ordinary_wall_reinforcement!`).
- order dependence: round-robin by lowest ρt ⇒ spreads steel evenly rather than to the most efficient (longest) walls; ties by index.
- cost per pass: cheap.
- size impact: LOW–MED (even spreading instead of cheapest-per-φVn allocation; the 75% target itself is code-mandated).
- speed impact: LOW
- opportunities: allocate by marginal φVn per unit steel volume (lw·t·Δρ) — greedy on efficiency; or solve the small LP directly.
- confidence: verified-by-reading

### Row F frame section floors (§12.2.5.8 frame 25% check)
- location: SSy/analyze/lateral/interactive_checks.jl:840-930, `_raise_frame_floors!`; frames solved without wall shells at 25% story shear (:470 `exclude_shells=true`); floor consumed by SSy/analyze/members/members/size_columns.jl:238 and size_beams.jl:991-997; reset only in SSy/workflow/prepare.jl:117.
- decision variables: per member-group catalog floor `struc.frame_section_floors[gid]`.
- inputs / outputs: failing frame member check → lightest catalog section ≥ current objective that passes for **all members in the group** (:902-913); with `uniform_columns` the whole story/building cohort shares the floor (:848-875). Triggers a member re-size round in `_walls_with_member_recheck!`.
- stop rule + budget + step size: catalog walk (sorted by objective); outer budget = 4 walls⇄members rounds.
- monotone? Yes — "Sections only move up" (:824-825); floors persist for the run.
- order dependence: floors set on round k persist even if wall thickening in round k+1 would have relieved the frame — but the 25% frame check is solved without walls, so it is independent of wall thickness (only of story shear V, which is independent of wall stiffness given user T).
- cost per pass: one frame-only solve per gravity key (:470) + catalog walk.
- size impact: MED — group envelope (all members in gid must pass) and uniform-column cohort expansion make one failing member upsize the cohort.
- speed impact: MED
- opportunities: let row F demands feed the member sizer as an extra load case instead of a floor (sizer then picks per-group optimum jointly with gravity); avoid cohort-wide floors when uniform sizing is off.
- confidence: verified-by-reading

### sync_asap! / update_analysis! (analysis refresh after resize)
- location: SSy/analyze/asap/asap/model_sync.jl:120-193 `sync_asap!`; :335-351 `update_analysis!` (`:loads` → loads_only sync; `:stiffness` → `_reanalyze_after_section_change!` SSy/workflow/member_iteration.jl:174-186; `:geometry` → `to_asap!` + `_restore_sized_frame_state!` :379-396 which ends in a full `sync_asap!`); stiffness token for factor reuse :18-66, :80-83.
- decision variables: none — re-derives loads from current sizes: slab self-weight into cells (:124-129), tributary pressures `envelope_pressure(combos, D, L)` (:146-153) or split D/L for patterns (:137-145), joist seat eccentricity (:163), shell-area pressures (:164, :244-266), wall self-weight `_sync_wall_self_weight!` (SSy/analyze/asap/asap/pattern_cases.jl:235-246), drop panels, member self-weight, fire coating, vault thrust, edge strips (:165-170). Then `Asap.update!` and solve (single or pattern cases, :184-190).
- stop rule: n/a (called by loops). Note `:stiffness` path does **not** refresh slab/cell loads — only sections + member self-weight (GravityLoad reads the section).
- monotone? n/a
- order dependence: pipeline-level — `sync_asap!` after stage 1 (needs_sync) and after non-flat member stage (pipeline_spec.jl:113-122); flat member path syncs inside its settle! loop (SSy/workflow/graph_builder.jl:394).
- cost per pass: full re-assembly + factorization (unless loads_only and token unchanged) + 1 or N_pattern solves.
- size impact: LOW directly. Indirect: tributary pressure is `envelope_pressure` across all combos (single governing envelope pressure), and foundation `Pu` reads node reactions of this envelope solve (see foundation demand record).
- speed impact: HIGH (`:geometry` = full model rebuild per wall-thickness pass).
- opportunities: a `:wall_thickness` change kind that mutates `ShellTri3.thickness` in place (mesh unchanged when only t changes) instead of `to_asap!` rebuild — the Winkler mat path already does exactly this (SSz/foundations/codes/aci/mat_winkler/design.jl:233-238 + `Asap.update!(model; values_only=true)` solve.jl:56). Check whether wall meshing depends on t (offsets/joints) before doing so.
- confidence: verified-by-reading

### Beam/column resize loop and column harmonization (context: feeds walls & foundations)
- location: SSy/workflow/member_iteration.jl:345-377 `_iterate_beams_columns!` (max_iter = `params.max_iterations`, default 20, SSy/design/parameters.jl:286); story-shell rounds :397-459 (max_rounds 3); columns-only :278-291; uniform harmonization (max(c1)×max(c2) per story/building) member_iteration.jl:30-60 → `update_structural_offsets!` (SSy/analyze/members/members/geometry_classification.jl:357-375: resets offsets, recomputes inward normals, refreshes edge-strip tributaries) + `_resolve_after_column_change!` (SSy/workflow/column_reconciliation.jl:227). Flat-plate: `_design_flat_plate_members!` settle! (SSy/workflow/graph_builder.jl:373-403) and `check_flat_plate_columns!` grow-only settle! (SSy/workflow/flat_plate_column_check.jl:687-725, budget `monotone_budget(max_iterations, catalog length)`).
- decision variables: beam/column sections (owned by members mapping); here only their coupling matters.
- inputs / outputs: each iteration = size beams → `update_analysis!(:stiffness)` → size columns → harmonize → `update_analysis!(:stiffness)`; stop when no section changed. Columns c1/c2 feed foundation punching (`initialize_supports!` SSy/analyze/foundations/supports.jl:46-60, default 18 in when unsized) and wall-stage stiffness.
- stop rule + budget + step size: identical sections; budget 20; story-shell 3 rounds with `upward_only` ratchet (:407-409).
- monotone? Flat-plate column check: yes (grow-only, :676). Beam/column loop: not globally grow-only except story-shell `upward_only` and frame floors.
- order dependence: beams before columns each pass; harmonization after columns.
- cost per pass: 2 stiffness re-solves (+ pattern cases) per iteration.
- size impact: MED for this scope — `uniform_column_sizing` (default `:off`, parameters.jl:217) envelopes columns; frame floors/upward_only ratchets carry earlier-pass forces.
- speed impact: HIGH (re-run in full in every walls⇄members round).
- opportunities: warm-start the member loop after a wall jump with only the members whose demand changed > tol.
- confidence: verified-by-reading (loop structure); member sizing internals out of scope.

### No outer whole-building iteration
- location: SSy/workflow/pipeline_spec.jl:61-147 (`build_pipeline`), executor SSy/workflow/execute.jl:15 / SSy/design_graph/executor.jl:48
- decision variables: —
- inputs / outputs: stages run once in order slabs → members → walls(+member recheck) → foundations.
- stop rule: none; single pass.
- monotone? n/a
- order dependence: **strong**. Slabs (stage 1) are sized before walls exist at final thickness; a wall jump changes slab support stiffness but slabs are never re-designed (`_slab_moment_into_wall` reads slab envelopes from stage 1, ordinary_wall_stage.jl:937-958). Foundations read whatever the last solve left.
- cost per pass: —
- size impact: MED — wall out-of-plane moment `Moop` comes from stage-1 slab envelopes, taken as **max** over slabs at top/bottom joints and over primary/secondary directions (:955-966), independent of the axial N it is paired with; e = Moop/N with low-N combos (0.9D) pushes e > t/6 and the pier into the magnified out-of-plane check (wall_ordinary_check.jl:102-114), which then drives ρl (wall_ordinary_check.jl:405-406) and thickness.
- speed impact: LOW (absence of a loop)
- opportunities: pair Moop with the concurrent slab load combo (gravity combos share D/L factors); after a wall jump, re-run only the slabs whose supports changed.
- confidence: verified-by-reading (single pass); Moop/N pairing inferred from `_out_of_plane_passes` (:348-356) applying one Moop to every action.

### Foundation demand extraction (single pass, gravity envelope)
- location: SSy/workflow/capture_results.jl:18-45 `_size_foundations!`; SSy/analyze/foundations/supports.jl:11-70 `initialize_supports!` (reads `node.reaction` of the current model); SSy/analyze/foundations/demands.jl:117-140 `support_demands`, :57-68 `_service_reactions` (extra unfactored D+L solve reusing factorization), :14-37 `_unfactored_DL_loads`.
- decision variables: none.
- inputs / outputs: Pu, Mux, Muy, Vux, Vuy = reactions of the last sync'd solve (tributary pressure = `envelope_pressure` of the gravity combos, model_sync.jl:146-153; or pattern envelope); Ps from a separate service solve. Column c1/c2 from current column sizes (default 18 in., supports.jl:46-47).
- stop rule: single pass; foundations never feed back (stage `needs_sync=false`, pipeline_spec.jl:135-142).
- monotone? n/a
- order dependence: runs after walls⇄members; for flat floors the last member re-size in stage 3 is not followed by `sync_asap!` (`sync_after_members = !flat`, pipeline_spec.jl:132) — reactions can be one column-resize stale (column self-weight).
- cost per pass: 1 extra linear solve (service) with cached factor.
- size impact: LOW–MED — Pu/Mux/Muy come from the **envelope-pressure** solve, so moments and axial are each from the governing gravity envelope rather than concurrent pairs; lateral (wind/ELF) reactions are not included at all (the wall stage solves them separately and does not write node reactions) — an omission, not an over-size.
- speed impact: LOW
- opportunities: build per-combination concurrent (P, Mx, My) sets for footings; include lateral combos explicitly (needs a code-owner decision — flag, don't guess).
- confidence: verified-by-reading (sources); "lateral not included" inferred from wall-stage solves using `Asap.solve(...)` that returns displacements without updating `model` (ordinary_wall_stage.jl:839, elf_story_cases.jl:242).

### Foundation strategy selection (coverage heuristic)
- location: SSy/analyze/foundations/strategy.jl:47-107 `_resolve_strategy`; dispatch :340-408
- decision variables: strategy ∈ {spread, strip, mat}.
- inputs / outputs: coverage = Σ(Ps>0)/qa ÷ bounding-box area of **all skeleton vertices** (:66-75); > `mat_coverage_threshold` (0.50, SSz/foundations/options.jl:267) → mat, > 0.30 → strip, else spread.
- stop rule: one-shot.
- monotone? n/a
- order dependence: none.
- cost per pass: trivial.
- size impact: MED — bounding box over-estimates footprint for L/irregular plans (coverage under-estimated → spread chosen where a mat might be cheaper; or vice versa for tall vertex extents); thresholds are heuristics (no code clause), and there is no cost comparison between strategies.
- speed impact: LOW
- opportunities: compute footprint from the ground-story outline; size all candidate strategies and pick min volume/cost (each is cheap except Winkler mats).
- confidence: verified-by-reading

### Spread-footing grouping by reaction (greedy, envelope)
- location: SSy/analyze/foundations/grouping.jl:113-180 `group_foundations_by_reaction!`; group design :198-408 `size_foundations_grouped!` (governing demand :232-329); default tolerance 0.15 (strategy.jl:303; `fp.group_tolerance` capture_results.jl:36).
- decision variables: group membership; one footing per group.
- inputs / outputs: greedy clustering over foundations in order; a foundation joins the first group (Dict iteration order) whose representative load is within ±tol (:144-147); representative is updated to **max** (:150-151). Group design demand = component-wise max of Pu, Ps, |Mux|, |Muy|, |Vux|, |Vuy|, c1, c2 over members (:300-325) — **non-concurrent envelope**; column dims floored at 18 in. (:314-315).
- stop rule: one pass.
- monotone? Representative only grows ⇒ chaining: members can span more than ±tol (e.g. 100 → 114 → 130 kN all in one group).
- order dependence: yes — foundation order and `Dict` iteration order (:144) decide membership.
- cost per pass: one `design_footing` per group (threads, :359-368).
- size impact: **HIGH** — (a) every member gets the footing for the max of each demand component taken independently (max P from one column, max M from another, max c from a third); (b) chaining lets groups span >15%; (c) the 18 in. floor on c1/c2 (and max c across group) can make punching optimistic for small columns but is applied as the group's single column size — bearing area (B) is driven by max Ps.
- speed impact: LOW
- opportunities: sort loads descending before clustering and compare to the group's **min** (bound the spread to tol); design each group for each member's concurrent demand and take the envelope of resulting (B, h); allow tol=0 for min-volume runs; expose per-group utilization spread in the report.
- confidence: verified-by-reading

### Spread footing design (plan growth + depth bisection + development growth)
- location: SSz/foundations/codes/aci/spread_footing.jl:620-884 `design_footing(::SpreadFooting, …)`; plan loop :688-715; depth search :522-576 `_smallest_spread_footing_depth`, seed :449-492; development/plan attempt loop :728-834; options SSz/foundations/options.jl:108-144.
- decision variables: B (= L, square only, :678, :693, :703, :828), h, bar size/count, anchorage.
- inputs / outputs: demand (Pu, Ps, Mux, Muy, c1, c2, shape), soil qa.
- checks in order: (1) plan from Ps/qa rounded to `size_increment` (3 in.) with 6 in. min projection (:668-677); (2) kern (q_min ≥ 0) + service q_max ≤ qa per ACI 336.2R §3.2.1 Eq. 3-1 (:680-715); (3) per thickness: d ≥ 4 in., flexure tension-controlled, punching ACI 318-11 §11.11 incl. biaxial moment transfer, one-way shear §11.1.3.1 (:749-775); (4) flexural steel + min steel, spacing ≤ min(3h, 18 in.) §7.6.5 (:796-805); (5) development §12.2/§15.6.3 — smaller bar, hook, else **grow plan** by 3 in. and repeat (:812-828); (6) bearing/dowels §22.8 (:839-844).
- stop rule + budget + step size: plan ≤ 80 × 3 in. (:695) else error; depth grid h_k = min_depth (12 in.) + k·1 in., k ≤ 59, bisection from a closed-form punching seed (Eq. 11-33 fixed point) — returns smallest passing grid point (:522-576); development ≤ 40 plan attempts (:728).
- monotone? Yes within a call (B only grows, :702, :827); depth is minimal for the current plan.
- order dependence: plan first (bearing/kern), depth second — no trade-off of larger B for smaller h (min-volume not searched); `objective = MinVolume()` exists in options (:143) but is not used by this routine.
- cost per pass: closed-form; ~log2(60) predicate calls.
- size impact: MED — square-only plan (B = L) under one-axis moment wastes area (rectangular would satisfy kern with less); B rounded to 3 in. and h to 1 in.; development failure grows the whole plan rather than adding hooks/thickness options.
- speed impact: LOW
- opportunities: allow rectangular B×L (option `footing_shape` exists, :118, but code is square); search (B, h) jointly for min volume; consider deeper h vs larger B when development governs.
- confidence: verified-by-reading

### Strip / combined footing (B, h) nested loops
- location: SSz/foundations/codes/aci/strip_footing.jl:209- `design_footing(::StripFooting, demands, positions, …)`; L sizing :262-289; development loop :304-; (B,h) loops :330-422; caller SSy/analyze/foundations/size_isolated.jl:99-118 (designs along each tied axis and keeps the **worse** result, SSy/analyze/foundations/size_strip.jl:38-63).
- decision variables: L (symmetric about service resultant, 1 ft beyond end columns), B, h.
- checks in order: d ≥ 4 in.; tensile dowel embedment ld (§12.2.1, §15.8.1.2(b)) (:350-352); punching at each column (edge/interior) (:355-381); one-way shear at d from face (§11.1.3.1) (:383-401); flexure (:402-403); practicality h ≤ `max_depth_ratio`·B (0.5, options.jl:168) (:413).
- stop rule + budget + step size: inner h += 1 in. up to 80 steps (:340); outer B += 3 in. up to 30 (:335, :419); non-convergence only warns (:421).
- monotone? Yes (B and h only grow; h restarts at min_depth each B).
- order dependence: L fixed before B/h; development loop may lengthen L and keeps grown B (:322).
- cost per pass: closed-form V/M diagram per h step (≤ 2400 evaluations).
- size impact: MED — L = 2·max(half-lengths) about the resultant (:272-275) adds overhang on the short side; the h ≤ 0.5B rule (non-code, "Wight Ex 15-5") forces width growth beyond bearing need; when spans tie, designing both axes and keeping the worse (size_strip.jl:47-63) takes the larger design.
- speed impact: LOW
- opportunities: make the h/B rule optional or a cost trade-off; solve L with unequal overhangs within the property line; pick the **better** axis when both are valid layouts (current choice is "worse" — check intent before changing).
- confidence: verified-by-reading

### Spread→strip auto-merge (non-orthogonal fallback)
- location: SSy/analyze/foundations/strategy.jl:190-281 `_auto_merge_to_strips!`; orthogonal column-line grouping :119-179 (10% of l1 tolerance, cites ACI 318-11 §13.6.1.4).
- decision variables: which supports form strips.
- inputs / outputs: tentative B = √(Ps/qa) (min 0.3 m), D = max(0.15B, 0.3 m); merge when gap < `merge_gap_factor`(2.5)·D_max (:217, :239; options.jl:192).
- stop rule: one greedy pass, first-come pairing.
- monotone? n/a
- order dependence: yes — greedy by foundation index; a support merges into the first strip that claims it.
- cost per pass: O(N²).
- size impact: MED — merging when gap < 2.5·D can create long strips whose L/B loops (above) upsize; no cost comparison with the separate spreads.
- speed impact: LOW
- opportunities: merge only when the combined design volume < sum of separate designs (both are cheap to compute).
- confidence: verified-by-reading

### Mat — rigid (Kramrisch strips), plan/overhang + thickness loops
- location: SSz/foundations/codes/aci/mat_footing.jl:728-905 `_design_mat_rigid`; plan `_mat_plan_sizing` :58-184; strip moments `_rigid_mat_strip_moments` :447-469; dispatch/inapplicability fallback to Winkler :375-393, :573-.
- decision variables: overhang (uniform all sides), h, bar sizes.
- checks in order: overhang = max(punching c_max/2 + d_est/2, bearing quadratic, 2 ft) (:94-147); qu = ΣPu/(B·Lm) uniform; thickness: d ≥ 6 in., punching (all columns, corner detection) + wall cantilever shear + flexure + wall-dowel embedment (:794-808); As from strip moments × **full mat width** (:813-830); development → else grow overhang by `size_increment` and restart (:845-853); Kr ≥ 0.5 rigidity (ACI 336.2R Eq. 5-1, §5.2) else redesign as WinklerFEA (:375-385).
- stop rule + budget + step size: thickness 60 × 1 in. (warns only, :807); plan attempts 40 × 3 in.
- monotone? Yes (h, overhang grow).
- order dependence: plan before thickness.
- cost per pass: closed-form.
- size impact: **HIGH** — (a) moments use the worst span in each direction (max over spans, :455-466) applied uniformly across the full mat width (:436-443, :813-821), i.e. column-strip/worst-span intensity everywhere; (b) a single span between two column lines is treated as a cantilever wL²/2 (:457-458) — far above a simple-span wL²/8 (verify intent/source before changing); (c) uniform overhang on all four sides set by the governing requirement.
- speed impact: LOW
- opportunities: per-strip reinforcement (column vs middle strips per ACI 336.2R §6.1.2); per-side overhang; confirm the n==1 coefficient against ACI 336.2R with the corpus.
- confidence: verified-by-reading (code); engineering judgment on (b) needs code-owner review.

### Mat — Winkler FEA thickness sweep + no-tension active-set iteration
- location: SSz/foundations/codes/aci/mat_winkler/design.jl:22-476 `_design_mat_winkler_fea`; seed :150-172 (punching-only grid seed, `n_thick = 60 − k_h`); thickness loop :227-376; active-set solver SSz/foundations/codes/aci/mat_winkler/solve.jl:32-98 `_solve_winkler!`; options SSz/foundations/options.jl:88-94.
- decision variables: h (1 in. steps); springs active set (inner).
- inputs / outputs: mesh built once (Delaunay + column patches), springs from tributary area × ks (edge doubled, ACI 336.2R §6.9); each h: mutate shell thickness in place, `Asap.update!(values_only)`, solve, deactivate uplifting springs / reactivate contact until settled (≤ 20, tol 0.5% equilibrium), then column-strip integrated moments (δ band, half-span strip) × **full mat width** (:352-357), punching (uniform qu, :360-361), flexure, dowel embedment.
- stop rule + budget + step size: linear sweep from seed upward, ≤ n_thick steps (warns only); inner active-set ≤ 20 or error.
- monotone? h grow-only; active set non-monotone (deactivate/reactivate).
- order dependence: none across columns.
- cost per pass: **full FE solve × active-set iterations per 1 in. step** (no bisection, unlike spread/`depth_search.jl` seed).
- size impact: **HIGH** — governing column-strip moment intensity multiplied by the full mat width for both directions (comment "Conservative", :353); punching uses average qu rather than FE contact pressure.
- speed impact: **HIGH** — linear h sweep, each step an iterative nonlinear (active-set) FE solve.
- opportunities: bisection on h (the predicate is monotone in h for fixed plan — same pattern as `_smallest_spread_footing_depth`); warm-start active set from the previous h; strip-wise reinforcement instead of max×full width; read punching Vu from spring reactions inside the critical perimeter.
- confidence: verified-by-reading

### Grade-wall footings (wall strip / wall mat) — plan + thickness
- location: SSy/analyze/foundations/wall_groups.jl:536-577 `design_grade_wall_foundations` (closed wall rings → mat incl. enclosed columns; otherwise wall strip); SSz/foundations/codes/aci/wall_plan.jl:383-421 `_size_wall_plan`; SSz/foundations/codes/aci/wall_strip_footing.jl:30-55 dispatch, :180-229 `_design_wall_rigid`, :341-393 `_design_wall_winkler` (Kr < 0.5 fallback, ACI 336.2R §5.2/§5.4).
- decision variables: B (width), free-end extensions, h.
- checks in order: service pressure in [0, qa] (ACI 318-11 §15.2.2; ACI 336.2R Eq. 3-1) — if q_min < 0 extend the light free end, else widen B by `width_increment` (≤ 80 steps, wall_plan.jl:398-417); rigidity Kr; factored pressure must not lift (else Winkler/refuse, :183-192); per h (1 in., ≤ 60): d ≥ 6 in. (§15.7), shear/flexure `_wall_section_ok`, dowel development `_dowels_fit` (:209-224).
- stop rule + budget: as above; thickness non-convergence warns only (:225).
- monotone? Yes.
- order dependence: plan before thickness; wall thickness tw from the final jumped walls (`tw_max`, wall_plan.jl:387) — wall thickening widens the footing floor.
- cost per pass: closed-form (Winkler path: small beam-on-springs solve, ≤ 20 iterations, wall_strip_footing.jl:417).
- size impact: MED — one uniform B for an entire L/T assembly sized by the governing leg; B ≥ max wall thickness of the assembly.
- speed impact: LOW
- opportunities: per-leg widths; joint (B, h) search for min volume.
- confidence: verified-by-reading (loops); per-leg behaviour inferred from single `B` in `_size_wall_plan`.

### Out-of-plane service deflection fixed point (per check)
- location: SSz/walls/out_of_plane.jl:141-167 `oop_service_deflection_si` (ACI 318 alternative slender-wall method, Δs with P-Δ)
- decision variables: none (analysis inside a check).
- stop rule + budget: relative tol 1e-10, ≤ 100 iterations; non-converged result is not trusted (:270-272).
- monotone? n/a
- cost per pass: trivial.
- size impact: LOW. speed impact: LOW.
- opportunities: none material.
- confidence: verified-by-reading

---

## Part A — Decision space per element type

### Ordinary concrete walls (piers)
- Design variables: thickness t per thickness group (whole inches; `params.wall_thickness_grouping`, default `:pier`, so each wall has its own thickness; `:all` remains available). ρt and ρl on the grid 0.0025:0.0005:0.0200, re-picked from the code floor on every call. Length/layout fixed.
- Candidate generation / step: t from the next inch above t0. The catalog starts at `wall_thickness_limit` (36 in). `:hard` errors past it; `:soft` steps by 12 in and errors at 72 in. ρ by 0.0005 steps.
- Objective: implicit "thinnest inch the frozen-demand proxy accepts" (wall_thickness_jump.jl:416-463), then lightest ρt (from Eq. 11.5.4.3), then lightest ρl passing flexure/out-of-plane (wall_ordinary_check.jl:374-410). No carbon/cost objective (the StructuralSizer layout NLP with `MinCarbon` at SSz/walls/layout_problem.jl:95-120 is not wired in).
- Checks in order per action (wall_ordinary_check.jl:93-131): in-plane shear ACI 318-19 §11.5.4.3 → minimum reinforcement §11.6.2 → in-plane axial-flexure §22.2/§22.4.2.1 → out-of-plane: empirical bearing §11.5.3 if e ≤ t/6 else magnified out-of-plane strength §6.6.4.5/§22.2 (incl. Pu ≥ 0.75Pc failure, :158-159) → joined-leg out-of-plane resultants reported only. Before them, per pier: second-order moment limit §6.2.5.3 (ordinary_wall_stage.jl:1012-1028). Building level: story drift ASCE 7-22 §12.8.6/§12.8.7, θ limits, B.6 20% gravity share (C12.2.1 project limit), row F §12.2.5.8 75%/25%, special-boundary §18.10.6.3/§18.10.6.4 web width (raises t per pier, wall_thickness_jump.jl:583-589, 600-620), pierced-wall segment checks, joints / corner shear friction.
- Flanged section: one return is an L or a T. Returns at both ends are one C-section (Whitney block, width bf in each flange and tw in the web, corners once). A pierced segment stays its own rectangle and takes only the return bars whose station falls inside it. A flexible lateral floor with an empty story-drift list does not pass.
- Grouping rules: `wall_thickness_groups` — :all, :story, :wall_line (collinear connected run, union-find), :pier_stack, :wall_line_story, :pier (wall_thickness_jump.jl:82-104, 160-186). Drift and interactive story shear are applied to **every** group (:486-495).

### Spread footings
- Design variables: B (= L, square), h, bar size/count, anchorage type.
- Step sizes: B 3 in. (`size_increment`), h 1 in. from 12 in. (options.jl:121-123).
- Objective: smallest B satisfying bearing/kern, then smallest h on grid; `MinVolume()` declared (options.jl:143) but unused in the routine.
- Checks: see spread footing record (bearing/kern ACI 336.2R Eq. 3-1 → punching ACI 318-11 §11.11 (+§11.11.7.2 moment transfer) → one-way shear §11.1.3.1 → flexure/min steel/spacing §7.6.5 → development §12.2/§15.6.3 → bearing/dowels §22.8).
- Grouping: reaction-similarity greedy clustering ±15% with max-representative, then component-wise max demand per group (grouping.jl:113-180, 232-329).

### Strip / combined footings
- Variables: L (about service resultant), B, h, long/trans bars; step 3 in. width, 1 in. depth; h ≤ 0.5B practicality rule.
- Checks: tensile dowel ld (§15.8.1.2(b), §12.2.1) → punching each column → one-way shear at d → flexure → development; mixed-sign groups forced to strips with As_tensile (grouping.jl:250-281).
- Grouping: orthogonal column lines (10% l1 tolerance) or greedy proximity merge (gap < 2.5·D).

### Mats
- Variables: uniform overhang, h, bar sizes x/y; method Rigid (default) / Shukla AFM / Winkler FEA (options.jl:14-94, 224).
- Checks: bearing (Ps/qa) → punching per column (corner detection) → wall cantilever shear → flexure → development (grow overhang) → rigidity Kr (ACI 336.2R Eq. 5-1) → Winkler fallback.
- Grouping: one mat for all supports (strategy :mat) or for a closed grade-wall ring + enclosed columns (wall_groups.jl:549-565).

### Piles
- Not implemented: only a `PileCapResult` export (SSz/StructuralSizer.jl:739) and a `:pile` foundation_type comment (SSy/building_types/foundations.jl:16). No pile sizing loop exists.

---

## Top-5 by size impact

1. **Uniform drift/global-check thickness fix across all wall groups** — drift and interactive shear are still handed to every group, and `_drift_scale` takes the max ratio over all stories/directions. The default grouping is `:pier`, so a local pier failure thickens that wall only. `:all` remains available and still thickens every wall together. Grow-only, never relaxed. HIGH for drift; the local-failure half is closed.
2. **Mat reinforcement from worst-span / column-strip intensity × full mat width** (rigid: SSz/foundations/codes/aci/mat_footing.jl:447-469, 813-830; Winkler: SSz/foundations/codes/aci/mat_winkler/design.jl:352-357), plus the single-span cantilever coefficient wL²/2 (mat_footing.jl:457-458). HIGH.
3. **Foundation group envelope** — non-concurrent component-wise max of Pu/Ps/Mux/Muy/V/c over a greedily chained ±15% cluster whose representative only grows (SSy/analyze/foundations/grouping.jl:144-151, 300-325). HIGH.
4. **Wall out-of-plane moment** — Moop = max slab envelope (stage-1 slabs, never re-designed) paired with every axial, including low-N combos. The reinforcement ratio is no longer kept from an earlier pass. MED.
5. **Square-only spread footings and h ≤ 0.5B strip rule** — B = L under eccentric load (SSz/foundations/codes/aci/spread_footing.jl:678, 690-704) and non-code width growth in strips (SSz/foundations/codes/aci/strip_footing.jl:330, 413-419), plus row F frame floors/cohort envelopes (SSy/analyze/lateral/interactive_checks.jl:848-920). MED.

Speed hot spots (for reference): wall-thickness passes each do a full `to_asap!` rebuild + several K_G solves (model_sync.jl:347-350; ordinary_wall_stage.jl:831-846) and re-trigger the full member loop (pipeline_spec.jl:178-189); Winkler mats sweep h linearly with an iterative active-set FE solve per inch (mat_winkler/design.jl:227-376).

