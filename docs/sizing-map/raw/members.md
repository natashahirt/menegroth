# Member sizing map (columns, beams) — raw

Scope: StructuralSizer/src/members/**, StructuralSizer/src/optimize/**, and member-stage callers in StructuralSynthesizer/src.
Status: COMPLETE (first pass). Part B loop records first; Part A (decision space, grouping, slab feedback, anomalies) and the top-5 list follow. Defaults: `DesignParameters.max_iterations = 20`, `uniform_column_sizing = :off`, `collinear_grouping = false`, `column_I_factor = 0.70`, `beam_I_factor = 0.35` (SY/design/parameters.jl:156, :217, :282-286).

Path abbreviations: `SS/` = `StructuralSizer/src/`, `SY/` = `StructuralSynthesizer/src/`.

---

# PART B — loop records

### Pipeline stage-2 dispatch (context, not a loop)
- location: SY/workflow/pipeline_spec.jl:113-122, `build_pipeline`
- Flat plate / flat slab → `_design_flat_plate_members!` (SY/workflow/graph_builder.jl:373); everything else → `_size_beams_columns!` (SY/workflow/member_iteration.jl:210). Stage 1 (`design_floors!`, pipeline_spec.jl:90-107) has already sized slabs AND, for flat plates, columns from tributary Pu inside the slab loop with `max_iterations = params.max_iterations`.
- Sync flag: flat path is `false` (self-syncing), beam path `true` (pipeline_spec.jl:122).
- confidence: verified-by-reading

### Beam ↔ column fixed-point loop (`_iterate_beams_columns!`)
- location: SY/workflow/member_iteration.jl:345-377, `_iterate_beams_columns!` (called from `_size_beams_columns!` :319 and from story-shell rounds :420)
- decision variables: every beam group section (catalog MIP / NLP / RC catalog), every column group section; then uniform-column promotion.
- inputs it depends on / outputs it feeds: FE forces from `struc.asap_model` (with self-weight `GravityLoad`s added by `_add_gravity_loads!`, SY/analyze/members/members/size_columns.jl:382), fire-coating loads; `shell_demands` (held fixed per round); `section_floor` when `upward_only`. Feeds Asap sections (stiffness), fire coating loads, walls/foundations stage.
- stop rule + budget: stop when a full pass changes no beam AND no column section (`_sections_identical`, :364-367); budget `params.max_iterations` (default 3 in `size!`; API default 20, SY/api/deserialize/floors.jl:65). Non-convergence → `stage_diagnostics[:members]` (:466-475), design marked not converged, NOT an error.
- monotone? NO by default. Each pass re-runs a fresh `size_beams` / `size_columns` MIP from scratch on the new forces; sections may shrink. Grow-only only when `upward_only=true` (story-shell path, `_shell_ratchet_ok`: discrete steel, or rectangular discrete concrete, with one material and `n_max_sections = 0`), and then only for beams via `section_floor = _section_floors(struc)` (:354). Columns are never ratcheted here.
- order dependence: Gauss-Seidel: beams sized on old columns, re-solve, columns sized on new beams, harmonize, re-solve. Beams-first is fixed. Harmonize (`_harmonize_columns!`) runs inside the pass, so the convergence test compares post-harmonization sections.
- cost per pass: 2 × `update_analysis!(:stiffness)` (stiffness re-assemble + re-solve + pattern cache), 1 beam MIP (or per-group NLP), 1 column MIP, plus `member_group_demands` station sampling (resolution 200, per pattern case) twice; capacity precompute for each catalog each call (cache is per-call, not persisted across passes — see column/beam API records).
- size impact: MED. (a) Group envelope pairs max P with max M across pattern cases and members (SY/analyze/members/members/demands.jl:675-678) — conservative by construction. (b) Hitting `max_iterations` exits with whatever the last pass produced, which may be sized on forces from a previous stiffer/heavier state; no "take the last feasible-on-final-forces" step. (c) Not grow-only so no ratchet inflation, but oscillation between two catalog neighbours ends at budget on whichever is last (could be the larger).
- speed impact: HIGH (dominant member-stage cost; two FE solves + two MIPs per pass).
- opportunities: persist capacity caches across passes (catalog × material fixed); warm-start MIP with previous assignment; test convergence per group and only re-size groups whose demand moved beyond a tolerance; cycle detection (A→B→A) to stop early and pick the feasible-on-current-forces one.
- confidence: verified-by-reading

### Columns-only loop (no beam edges)
- location: SY/workflow/member_iteration.jl:276-291, `_size_beams_columns!` (no-beam-edges branch)
- decision variables: column sections (steel default, or concrete when all floors are two-way/grade/roof, `_beamless_column_options` :195-202).
- inputs/outputs: frame forces incl. column self-weight and fire coating → column sections → stiffness.
- stop rule + budget: no column section changed; `max(1, params.max_iterations)`. Non-convergence recorded, not error.
- monotone? NO (fresh MIP each pass).
- order dependence: none beyond size → harmonize → coat → re-solve.
- cost per pass: 1 column MIP + capacity precompute + 1 stiffness re-solve.
- size impact: LOW-MED (same envelope pairing; harmonization inside loop).
- speed impact: MED.
- opportunities: same as above; cache capacities across passes.
- confidence: verified-by-reading

### Legacy `size!` beam/column loop
- location: SY/core/size.jl:92-125, `size!(design)`
- decision variables: beam + column sections.
- inputs/outputs: same as `_iterate_beams_columns!`, no harmonize, no fire coating.
- stop rule + budget: column axial demand change < `convergence_tol` (5%) between passes (`_extract_column_demands!`/`_max_demand_change`); `max_iterations = 3`. Minimum 2 passes. Converging on demand (not on sections) means sections can still be moving.
- monotone? NO.
- order dependence: beams then columns.
- cost per pass: 2 stiffness updates + 2 MIPs.
- size impact: LOW (exported convenience path; pipeline does not use it).
- speed impact: LOW.
- opportunities: delegate to `_iterate_beams_columns!` so there is one loop.
- confidence: verified-by-reading

### Story-shell rounds (beam-based floors with shell-designed stories)
- location: SY/workflow/member_iteration.jl:397-459, `_size_with_story_shell!`; inner `size_beams_with_story_shell!` SY/analyze/members/members/size_beams_story_shell.jl:145 (`max_passes=10`)
- decision variables: beam sections (from max(frame, shell) demands), column sections via the inner `_iterate_beams_columns!`.
- inputs/outputs: story shell (meshed once per story, cached in `shells`) gives beam moment/shear demands (never lowers frame demand, demands.jl:569-571); shell solved with column rotational springs; output: beam/column sections + slab bars from final shell.
- stop rule + budget: `held = sb.converged && sb.service_converged && beams_held && columns_held` (:430); `max_rounds = 3` (hard-coded). Non-settle → warn + slab `converged=false` (:455-457, :481-491).
- monotone? Beams grow-only after round 1 when `upward_only` (discrete steel, or rectangular discrete concrete): `floor = _section_floors(struc)` (:453) passed as `section_floor`. Columns not monotone. T-beams are not floored.
- order dependence: shell → frame loop → next shell seeded with previous demands (`seed`, :452).
- cost per pass: up to 10 shell solves inside `size_beams_with_story_shell!` + a full `_iterate_beams_columns!` (up to max_iterations passes) per round. Worst case 3 × (10 shell + max_iter × 2 frame solves).
- size impact: HIGH for beams. Upward ratchet: once a beam is floored at round-k section, a later round with relaxed shell demand (e.g. stiffer neighbor attracted load away) cannot shrink it. Shell demand is an envelope max(frame, shell) per beam group. Seeded demands are from the previous (possibly heavier) state.
- speed impact: HIGH.
- opportunities: allow a final "relax" pass (size without floor, accept if feasible on final shell); stop shell rounds when the column/beam change set is empty except for floor-only promotions; per-story independence (only re-shell stories whose supports changed).
- confidence: verified-by-reading (outer); inner `size_beams_with_story_shell!` pass loop not fully read — inferred.

### Flat-plate member stage (stale-slab redesign loop)
- location: SY/workflow/graph_builder.jl:373-409, `_design_flat_plate_members!`
- decision variables: column c1×c2 + bars (via reconcile / full-load check / stacking / harmonize), slab thickness & reinforcement of stale slabs (re-run of the isolated floor design).
- inputs/outputs: inputs = frame forces after `sync_asap!`, installed column sizes; slab is "stale" when its stored checks used a smaller column than installed (`_slab_checked_at_installed_columns`, :339-343). Re-design via `_isolated_floor_outcome` → `_commit_floor!` → `_apply_support_envelope!` (support update keeps largest footprint that does not shrink either side, `_support_beats` :448-452). Output: column sizes feed slab punching perimeter (b0), `ln = l1 − c1`, joint unbalanced moment; slab depth feeds frame dead load.
- stop rule + budget: settle! until no stale slab; budget `monotone_budget(params.max_iterations, 48)` = max(max_iter, 48) (SS/iteration.jl:35-43). Non-settle → hard `error` (:402-405).
- monotone? YES, columns grow-only: `_support_beats` (graph_builder.jl:448), `_grow_flat_plate_columns!` covers current size (`_section_covers_column`), `_stack_*`, harmonize max. Slab redesign starts fresh but at ≥ columns.
- order dependence: within a round, stale slabs are designed in index order but via `_isolated_floor_outcome` and envelope-merged afterwards (order-independent merge); `_flat_plate_slabs_share_columns` (:418) exists because sequential sizing is order dependent.
- cost per pass: N_stale slab designs (each its own EFM/FEA + punching loop), full `sync_asap!` (re-mesh/re-solve), `_reconcile_columns!` (which itself runs the full-load check settle loop with re-solves).
- size impact: HIGH. Columns never relax: a column grown in round k because the slab was thin/punching-critical stays even if the redesigned slab (now with a bigger column) would no longer need it. Slab redesign at a bigger column is also never allowed to shrink the column back. Harmonize then spreads the max across the story.
- speed impact: HIGH (each round = slab redesigns + full sync + reconcile).
- opportunities: one joint (slab, column) pass that sizes column for punching with a candidate thickness rather than ping-pong; only re-design slabs whose columns actually changed by > increment; memoize slab outcomes keyed on (slab, support sizes).
- confidence: verified-by-reading

### Column reconciliation (axial growth from frame Pu)
- location: SY/workflow/column_reconciliation.jl:266-337, `_reconcile_columns!`
- decision variables: c1, c2 (grow by `size_increment`, shape/aspect constraints) and bar layout.
- inputs/outputs: first installs every sized RC column frame section + self-weight (`_install_sized_column_frame!` :208-220) and re-solves; then per column `Pu = max compression at element ends` (`_column_asap_Pu`, member_iteration.jl:157-171). `Ag_req` from ACI 318-11 Eq. (10-2) at ρg=0.01 (`tied_column_area_for_axial`, :294). Then calls `check_flat_plate_columns!` (:329).
- stop rule + budget: single pass over columns (no loop), all columns use the one Pu from the pre-growth solve; re-solve once afterwards if any grew (:323).
- monotone? YES: only grows (`c_required > c1 || > c2`, :298).
- order dependence: none within the pass (Pu snapshot taken before any growth; but growth of upper columns adds self-weight not seen by lower ones until the next call).
- cost per pass: 1 stiffness re-solve to install frame + 1 if grown (`_resolve_after_column_change!`, values-only `Asap.update!` + solve + pattern cache, :227-233).
- size impact: MED. (a) Axial-only growth at ρg=0.01 ignores the slab-loop P-M section which might have more steel: a column passing P-M with higher ρg is still grown to the ρg=0.01 area. (b) Bars are then kept only if 0.01≤ρg≤0.08 else minimum layout (:132-153), so the grown column may carry a different design than P-M optimal. (c) Pu uses `max(P_start, P_end)` from the envelope/full-load solve.
- speed impact: MED.
- opportunities: grow with the P-M catalog (the full-load check already does) instead of the ρg=0.01 axial formula, or use the current section's ρg in Eq. (10-2) — would avoid double-growing. (Engineering: Eq. (10-2) with actual ρg is a code-consistent alternative; confirm with user.)
- confidence: verified-by-reading

### Flat-plate full-load column check + stacking (settle loop)
- location: SY/workflow/flat_plate_column_check.jl:686-725, `check_flat_plate_columns!`; growth `_grow_flat_plate_columns!` :615-657; stacking `_stack_flat_plate_columns!` :492-551
- decision variables: RC catalog section per failing column (lightest by `obj_coeffs` that covers current size, ≤ `max_column_size` cap, passes P-M in both demand orientations and the joint check).
- inputs/outputs: `flat_plate_column_checks` (frame axial + ACI 318-11 §13.6.9.2 end moments); output grown sections installed on frame.
- stop rule + budget: settle! until a round grows nothing; budget `monotone_budget(max_iterations, length(catalog))` capped at 48. Non-converged → `stage_diagnostics[:flat_plate_columns]`.
- monotone? YES: candidates must cover current c1×c2 (`_section_covers_column` :462); stacking forces lower ≥ upper (design policy, not code, :489-490); visited top-down (:502).
- order dependence: stacking top-down propagates growth down in one pass; growth uses stale `checks` computed before this round's stacking.
- cost per pass: P-M capacity precompute per material (`precompute_capacities!` on whole catalog, :627-631 and :520-524 — recomputed EVERY round and separately in grow and stack, caches are local `Dict`s), 1 values-only re-solve.
- size impact: HIGH. (a) Covers-current-size constraint: a column can only be replaced by a section ≥ in both dims, so a previously enlarged dimension never comes back (e.g. a rectangular grown in c1 keeps c1 even if a squarer section would pass). (b) Stacking policy forces lower columns ≥ upper even when lower demand is satisfiable with a smaller section. (c) Each growth adds self weight and stiffness → more §13.6.9.2 moment to stiffer column → may trigger more growth (stiffness attracts moment).
- speed impact: MED-HIGH (catalog precompute repeated each round ×2).
- opportunities: hoist capacity caches out of the settle loop (catalog+material fixed); reuse the cache between grow and stack; consider "lightest section ≥ required" without covers-current when nothing else depends on the column size yet.
- confidence: verified-by-reading

### Uniform column harmonization
- location: SY/workflow/member_iteration.jl:25-62 `harmonize_uniform_column_sizes!`, RC :65-107, steel :110-150; wrapper `_harmonize_columns!` SY/workflow/graph_builder.jl:336-337
- decision variables: per group (`:per_story` = `col.story`, `:building` = all) RC → max(c1) × max(c2) independently (can create a section larger than any member had); steel → section of largest area.
- inputs/outputs: sizes after sizing; outputs frame sections + one values-only re-solve (:55-58).
- stop rule + budget: single pass; called inside every beam/column pass and every flat-plate round.
- monotone? YES (max).
- order dependence: none.
- cost per pass: one re-solve if changed.
- size impact: HIGH when enabled (`uniform_column_sizing ≠ :off`). Max-c1 and max-c2 are taken from possibly different columns → envelope section; steel picks max AREA, not the section that satisfies all demands at least weight; RC grown columns get `_assign_flat_plate_column_section!` (minimum layout, not P-M redesign). Harmonized sizes then feed back as demand (stiffness attracts moment) and, in the flat path, make slabs stale.
- speed impact: LOW (itself), MED indirectly (triggers stale-slab rounds).
- opportunities: size each group jointly in the MIP (shared variable) instead of post-hoc max — the discrete MIP already supports groups; pick the lightest catalog section covering all member demands rather than max dims; for RC use a catalog section covering max(c1), max(c2) rather than raw max dims.
- confidence: verified-by-reading

### Walls ↔ members recheck rounds
- location: SY/workflow/pipeline_spec.jl:166-195, `_walls_with_member_recheck!`
- decision variables: wall thickness (grow, whole inches), `frame_section_floors` from row-F frame check (SY/analyze/lateral/interactive_checks.jl:919), then all member sections via the stage-2 function.
- inputs/outputs: wall stage changes model → members re-sized (full stage 2 again) → `sync_asap!` (beam path) → walls re-checked.
- stop rule + budget: stop when wall thicknesses and floors are unchanged and no RC frame column fails P–M on that solution, or member sections are unchanged after re-size; `max_rounds = 4`; non-settle → `stage_diagnostics[:wall_members]`. A failing frame column is floored at its current section first (`_floor_overstressed_frame_columns!`), because the member stage ran before the walls were in the model.
- monotone? walls and floors YES (thickness only grows, floors only heavier — docstring :161-162); members re-sized fresh but floored groups masked.
- order dependence: walls before members each round.
- cost per pass: a full stage-2 (entire beam/column fixed point or flat-plate stale loop) + full sync per round. Up to 4× stage-2 cost.
- size impact: MED-HIGH. Section floors never relax: a group floored in round 1 under a thinner-wall model keeps that floor after walls thicken and attract lateral load away from the frame.
- speed impact: HIGH (re-runs whole member stage).
- opportunities: re-size only groups whose demands changed; clear/recompute floors against the final wall state before the last member pass.
- confidence: verified-by-reading

### Row-F frame section floors (`_raise_frame_floors!`)
- location: SY/analyze/lateral/interactive_checks.jl:840-931 `_raise_frame_floors!` (called from `_check_frame_member_strength` :578-608); consumed by `_frame_floor_mask` SY/analyze/members/members/size_beams.jl:996-1017 (RC columns at SY/analyze/members/members/size_columns.jl:238-248, RC beams size_beams.jl:1518-1525)
- decision variables: per failing group, the lightest catalog section with objective ≥ max objective of the cohort's current sections that passes every row-F (seismic, ASCE 7 strength combos with E, 25% cases) demand row for every member in the cohort.
- inputs/outputs: row-F demand rows (second-order solved, slenderness OFF in checker `_column_checker_bundle` :623-632 because P-Δ already in forces); output `struc.frame_section_floors[gid]` → catalog mask "floor section or strictly heavier objective".
- stop rule + budget: linear catalog walk, first passing section (sorted by objective, :904-914). Outer termination via walls/members rounds (max 4).
- monotone? YES: walk starts at `o_now = maximum(objective of current sections)` (:903); mask keeps only objective ≥ floor (size_beams.jl:1013-1014). Floors are never removed.
- order dependence: with `uniform_column_sizing ≠ :off`, a failing column floors EVERY sizing group in its story/building cohort, and the chosen section must pass every column in the cohort (:848-876).
- cost per pass: per candidate, single-section capacity cache keyed by `objectid(section)` (:669-676) + all rows × members check. Cheap relative to FE.
- size impact: HIGH (lateral systems). (a) Floor = objective-sorted mask, not strength-sorted: a lighter section that is stronger for the governing check (e.g. deeper beam, different aspect column) is excluded forever. (b) Cohort flooring under uniform sizing: one failing column raises the whole story's floor to a section passing the worst member. (c) Floor never relaxes after later stiffening (walls thicken, other members grow).
- speed impact: LOW (walk) / HIGH indirectly (each new floor triggers a whole member-stage re-run).
- opportunities: store floors as "capacity requirement" (demand rows) rather than a section, so the sizer can pick any section that passes rows; recompute floors from scratch each walls round instead of accumulating.
- confidence: verified-by-reading

### Discrete MIP section assignment (`optimize_discrete`) — per call, not a loop
- location: SS/optimize/solvers/discrete/model.jl:112-360; multi-material SS/optimize/solvers/discrete/catalog_expansion.jl:~90-280
- decision variables: binary x[i,j] for group i, catalog index j ∈ feasible[i] (:290-291); optional z[j] when `n_max_sections > 0` (:293-300).
- inputs/outputs: precomputed cache (:204-210), per-group feasibility screen (all groups × all sections × `is_feasible`, threaded :216-245), objective Σ coeff_j·L_i (:303-306).
- stop rule + budget: MIP gap 1e-4, `time_limit_sec` (default 30 s). TIME_LIMIT with a feasible point is accepted with a warning (:318-322).
- monotone? n/a.
- order dependence: none; ties broken by `argmax` over x values (:331-332) — among equal-objective sections (e.g. same b×h RC with different bars) the pick is whatever the solver returns.
- cost per pass: capacity precompute every call when `cache === nothing` (true for the building-level `size_columns!`/`size_beams!` callers: SY size_columns.jl:162, :249 do not pass a cache); full feasibility screen; MIP build/solve. A value-keyed memo (cache.jl:24-72, 64 entries, cleared wholesale when full) short-circuits identical inputs, but the key includes `objectid(catalog)` (model.jl:167-174), so a rebuilt catalog (e.g. `rc_column_catalog(...)` called afresh, or `_frame_floor_mask` catalogs) misses. Note the docstring at cache.jl:17-22 says "rebuilt catalog hits" while model.jl:163-166 says it misses — the code uses `objectid`, so it misses.
- size impact: LOW in itself (it is exact on its inputs). With `n_max_sections == 0` the problem is separable: the MIP equals per-group argmin of objective over feasible.
- speed impact: MED-HIGH (called 2× per beam/column pass, inside slab loops, and for every composite confirmation).
- opportunities: when `n_max_sections == 0` skip JuMP entirely (argmin over feasible, as `optimize_binary_search` already does, SS/optimize/solvers/binary_search.jl:49-125); persist capacity caches across passes keyed on (catalog value, material, checker); for the screen, scan in objective order and stop at the first feasible (only valid when no coupling).
- confidence: verified-by-reading

### Flat-plate slab loop — column P-M step (Phase A2 / Phase B), stage 1
- location: SS/slabs/codes/concrete/flat_plate/pipeline/iteration.jl:447-599 (Phase A, `a_budget = monotone_budget(max_iterations, _thick_steps())` :447), :750-830 (Phase B punching, `b_budget = monotone_budget(max_iterations, _column_steps())` :750); outer :437. Column update `_update_column_sizes!` SS/slabs/codes/concrete/flat_plate/pipeline/column_updates.jl:90-139.
- decision variables: c1, c2 and bars of each supporting column (catalog MIP via `size_columns(...; cache=_col_cache)`), slab h.
- inputs/outputs: slab-level Pu (single-floor tributary, per column_reconciliation.jl:250-252 docstring) and EFM/FEA column moments (`_assign_column_design_moments!`), Mu_secondary as Muy. Output: column sizes → next moment analysis (stiffness), punching perimeter, `ln = l1 − c1`.
- stop rule + budget: column sizes stable within `column_tol` relative change (column_updates.jl:128-131); budgets as above (≥ max_iterations=20 default).
- monotone? YES: `col.c1 = max(c_span_min, c1_pm, c1_old)` and same for c2 (column_updates.jl:108-109). When the max-composed size differs from the P-M pick, bars are redesigned by `resize_column_with_reinforcement` (:122-125).
- order dependence: per-slab; columns shared by adjacent slabs grow in slab index order (graph_builder.jl:411-430 discusses this); dims maxed independently (c1 from one source, c2 from another).
- cost per pass: one moment analysis (EFM/FEA re-run — "Column growth changes stiffness → re-run moments each iteration", :740-742) + column MIP (cache hoisted once per slab, :195-219).
- size impact: HIGH. (a) Grow-only with independent per-dimension max: if P-M picks 16×20 after 20×16, result is 20×20. (b) `c_span_min` floor. (c) A column grown during an early h iteration (thin slab → higher moment share/punching) is never shrunk after h increases. (d) Columns then go through reconcile/full-load/stack/harmonize, all grow-only.
- speed impact: HIGH (each column change re-runs slab analysis).
- opportunities: allow the column to be re-picked from scratch each h iteration (only enforce monotonicity in the outer slab↔column handshake); compose dimensions from a single catalog pick covering both previous dims rather than per-dim max.
- confidence: verified-by-reading (column parts); slab-side punching logic not traced here.

### Beam sizing per framing level (sweep within one `size_beams!`)
- location: SY/analyze/members/members/size_beams.jl:142-188 (`size_beams!`), passes from `_beam_sizing_passes` :347-390
- decision variables: beam sections per framing level (level 1 joists → level 2 … → unclaimed groups = primary girders).
- inputs/outputs: each pass reads forces after the previous level's sections were installed; between passes `_reanalyze_after_section_change!` (member_iteration.jl:174-186: full `Asap.update!` or `process!` + solve + pattern cache).
- stop rule + budget: fixed sweep, one pass per (level, options) group + 1.
- monotone? NO (fresh pick each call).
- order dependence: YES, slab-outward (joists before girders) by design — girder loads come from installed joist self-weight.
- cost per pass: one full re-solve per level + `member_group_demands` for ALL beam groups each pass then filtered (`_beam_group_demands` :428-439 computes every group, keeps `accept`ed).
- size impact: LOW (correct load path order).
- speed impact: MED (k levels × full re-solve, and demands computed for all groups k times).
- opportunities: compute demands only for accepted groups (pass `accept` into `member_group_demands`); skip the re-solve after the last level when the outer loop re-solves anyway.
- confidence: verified-by-reading

### Composite steel beam confirmation passes
- location: SY/analyze/members/members/size_beams.jl:786-871, `_size_beams_impl!(::SteelBeamOptions, ::Val{:discrete})` recursing via `again` (:771-784)
- decision variables: steel W section + stud layout (PerStationComposite, AISC 360 Ch. I).
- inputs/outputs: pass 1 picks with scaled deflection; installs composite analysis (`_install_composite_analysis!`); pass 2 "locked" confirms the same section on solved deflection; on rejection an open search; pass 3 locked confirm.
- stop rule + budget: hard-coded ≤ 3 passes (+1 solved-search variant); throws "No feasible sections" if confirmation and solved search both fail (:821-825).
- monotone? Effectively: a changed section after a failed confirmation is solved then confirmed; the pass-1 section is never returned to.
- order dependence: none across groups (batched).
- cost per pass: MIP + composite analysis install + re-solve per pass.
- size impact: LOW-MED (solved-search may pick heavier steel when more studs would suffice; code comments say the scaling search can pick heavier studs on the same section, :843-846).
- speed impact: MED.
- opportunities: none urgent; share the capacity cache between passes.
- confidence: verified-by-reading (outer control); composite checker internals not read.

### Uniform column harmonization inside `_raise_frame_floors!` / sizing (cross-ref)
- See "Uniform column harmonization" above; also enforced in row-F cohorts.

### RC column NLP as-built repair (continuous strategy)
- location: SS/members/optimize/api/rc_columns_nlp.jl:342-393 `_rc_column_nlp_repair`; verify :410-419; multistart via SS/optimize/solvers/continuous_nlp.jl:312-405 (`n_multistart`, Ipopt `max_iter = maxiter`)
- decision variables: continuous b, h, ρg → snapped to `dim_increment`, even bar count.
- inputs/outputs: per-column demand; the max-Pu case is the positional "anchor" but the whole demand set is passed as `demand=d` (:510-514), and per columns.jl:380 a demand set is one constraint row per case on the NLP path; then as-built `ACIColumnChecker` on all cases. Results memoized by demand key (`_rc_nlp_batch`, :554).
- stop rule + budget: `while true` growing bar count, then b and h by `dim_increment` each, until as-built passes or both at `max_dim` (docstring :323-339).
- monotone? YES (grows only).
- order dependence: none.
- cost per pass: one checker call per trial; Ipopt solves per start.
- size impact: MED. Snapping to `dim_increment` and even bar counts, then (on an as-built miss) growing bars and then b AND h together by one increment each (docstring :323-332) rather than re-optimizing the governing dimension.
- speed impact: LOW-MED (only when `sizing_strategy = :nlp`).
- opportunities: on an as-built miss, grow only the dimension whose axis governs; re-solve the NLP with the snapped dims fixed instead of stepping both.
- confidence: inferred (repair loop read via docstrings/greps, not line-by-line)

### Story-shell inner passes + trim (`_story_shell_passes!`, `_trim_story_shell!`)
- location: SY/analyze/members/members/size_beams_story_shell.jl:238-290 (passes), :302-340 (trim), entry :145-226
- decision variables: steel/RC beam sections against max(frame, shell) demands; composite sagging regions.
- inputs/outputs: every pass re-solves each story shell with current sections (shell meshed once, cached in `shells`), merges demands, resizes beams.
- stop rule + budget: section vector unchanged AND region shift ≤ `region_tol` (0.05) AND service solve on (:278-283); `max_passes = 10`; `free_passes = 2` before the ratchet starts (:213, :285).
- monotone? After `free_passes`, YES: `floor = _section_floors(struc)` each pass (:285). `_trim_story_shell!` then tries one free pick on converged demands and keeps it only if it converges with a lower objective (:320-325), else restores the kept sections exactly (fallback to floor if exact fails, :328-336). Trim only runs on the first call (`!continuing`, :215); later rounds of `_size_with_story_shell!` pass `section_floor` → `continuing = true` → no trim.
- order dependence: all stories solved before resizing (Jacobi within a pass).
- cost per pass: N_story shell solves (+ service shell solve once on) + beam MIP.
- size impact: MED (trim mitigates the ratchet on round 1; rounds 2-3 of the outer loop have ratchet without trim).
- speed impact: HIGH.
- opportunities: allow trim at the last outer round too; skip re-solving shells of stories whose beam/column sections did not change.
- confidence: verified-by-reading

---

# PART A — Decision space by member type

## Columns

### RC rectangular / circular (ACI 318) — discrete (default `sizing_strategy = :discrete`)
- Design variables: one catalog `RCColumnSection` (b, h, bar size, n_bars, cover, tie) or `RCCircularSection` (D, bars, spiral) per sizing group.
- Candidate set: `rc_column_catalog(shape, catalog)` (SS/members/optimize/catalogs.jl:67-100). `:standard`/`:square` → `square_rc_columns()` sizes 8:2:36 in, bars #5–#11, n ∈ {4,…,16,20} (SS/members/sections/concrete/catalogs/rc_columns.jl:205-210; docstring at catalogs.jl:55 says 12–36 but code is 8–36); `:rectangular`, `:low_capacity` (8–24), `:high_capacity` (18–72), `:all` (8–72, bars to #18). Circular analogues :313-399. Custom catalog / explicit `catalog=` kwarg override (columns.jl:434-437). Constructor rejects layouts that violate spacing. `catalog_constraint` `:soft` (default) merges the next named catalog and warns when a group has no section (`:low_capacity` → `:standard` → `:high_capacity` → `:all`); the first step off `:standard`/`:square` adds squares only. `:hard` errors inside the named catalog. A custom catalog is not grown. Beams use the same switch; their default remains the tier growth.
- Objective: `MinVolume`/`MinWeight`/`MinCost`/`MinCarbon` — ALL use gross Ag only (SS/members/codes/aci/columns/checker.jl:536-624). `MinCost` for RC is a volume proxy (:559-568). Rebar is not in the objective, so at equal b×h all bar layouts tie; `MinCarbon` ignores rebar carbon.
- Checks (`_is_feasible_rc_column`, checker.jl:387-487): depth ≤ `max_depth`; nonsway moment magnifier both axes (ACI 318-19 §6.6.4, cap δns per §6.2.5.3 → `permitted`, :420-443) with Cm from signed M1/M2; Mux = max(Mux, Mc); P-M interaction from precomputed diagram (ACI 318-19 §22.4); weak-axis uniaxial (R6.6.4.5.4) or Bresler biaxial α=1.5 (:465-484). `RCColumnDemandSet` → every pattern case must pass (:363-377). k factors are static member properties (`base.Kx/Ky`), not updated from ψ.
- Capacity cache: `ACIColumnCapacityCache` — strong + weak P-M diagram per section, objective coeff, depth (checker.jl:80-90; precompute threaded :206-242). Built per `optimize_discrete` call unless passed (slab loop hoists one per slab: iteration.jl:195-219).
- Grouping: one group per `group_id`; columns have no group_id set anywhere in SY/src (only beams get `set_group_id!` in framing/materialize.jl:300-323 and `group_collinear_members!`), so each column is a singleton group (`build_member_groups!`, SY/analyze/members/members/demands.jl:35-61). `collinear_grouping` is read from `struc.design_parameters`, which does not exist on `BuildingStructure` (size_columns.jl:98-103, :117-118) → INERT even when `DesignParameters.collinear_grouping = true` (SY/design/parameters.jl:156). Cross-member sharing happens only post hoc via `uniform_column_sizing` (default `:off`, parameters.jl:217).
- Row-F floors (seismic) mask the catalog for floored groups (size_columns.jl:238-248).

### RC columns — NLP (`sizing_strategy = :nlp`)
- Variables: continuous b, h, ρg (`NLPColumnOptions`, columns.jl:494-525), min_dim 8 in, max_dim = `max_depth` or 48 in, bar #8 fixed, `dim_increment` snapping, aspect limit, optional square preference; Ipopt multistart.
- Objective: `opts.objective` (volume etc.). Checks: as-built ACI checker after snapping + repair (rc_columns_nlp.jl:342-419). Not allowed with row-F floors (size_columns.jl:239-242).

### Flat-plate columns (inside slab design + member stage)
- Variables: c1, c2 (+ bars) per column; sized inside the slab loop with that slab's Pu and EFM/FEA joint moments; then grown by reconcile (Eq. (10-2) at ρg=0.01), full-load P-M check (§13.6.9.2 end moments), stacking policy (lower ≥ upper), harmonize. Cap `max_column_size` from flat-plate options (flat_plate_column_check.jl:600-604). Growth increment `size_increment` (default 0.5 in, column_reconciliation.jl:278) vs catalog step 2 in.

### Steel W / HSS / pipe (AISC 360)
- Variables: one catalog section per group; `section_type ∈ {:w, :hss, :pipe, :w_and_hss}`, `catalog ∈ {:preferred/:compact_only, :all}` (catalogs.jl:22-38). Multi-material via `opts.materials` (catalog × material expansion, catalog_expansion.jl:16-36). Optional `n_max_sections` cap (couples groups).
- Objective: `MinWeight` default when no params (size_columns.jl:110), else `opts.objective`; coeff = A·ρ (·ecc, ·cost) per metre (objectives.jl:47-75).
- Checks (`is_feasible`, SS/members/codes/aisc/checker/steel_feasibility.jl:11-166): depth; shear strong/weak (Ch. G); strong-axis flexure with LTB at Lb, Cb (Ch. F); compression min(flexural x, y, torsional) at Kx·L, Ky·L (Ch. E); B1 (App. 8, A-8-1/A-8-3); hogging Chapter F at Lb=L, Cb=1 (§F2.2); H1-1a/b for compression and tension both faces (§H1.1/§H1.2); LL and total deflection by `δ·I_ref/Ix` scaling; story-shell spans. B2 not applied (warn if `braced=false`, :56-59).
- Steel NLP (`:nlp`) for W/HSS only, refuses composite, tension, shell spans (columns.jl:199-211).

### PixelFrame columns
- Catalog of pixel layups (`generate_pixelframe_catalog`), MIP via `size_columns(...PixelFrameColumnOptions)`, then per-pixel material assignment (size_columns.jl:264-379). Not traced further.

## Beams

### Steel beams (discrete MIP, default)
- Variables: W section per beam group (+ studs when `composite`); catalog via `steel_column_catalog(section_type, catalog)` also for beams (size_beams.jl:968-971).
- Objective: `opts.objective` (default MinWeight).
- Checks: same AISC checker as columns (Mu+, Mu−, Vu, Pu_c/Pu_t, δ_LL, δ_total, shell spans); composite: Chapter I per-station (`PerStationComposite`) with confirmation passes; deflection limits from options.
- Masks: `member_group_overrides` (per-group catalog/depth/deflection, union catalog + feasible mask), `section_floor` (story-shell ratchet), composite lock.
- Grouping: framing-level groups — one group per framing level for interior joists, separate edge-joist group and solid-head group (SY/analyze/framing/materialize.jl:292-326); all other beams singletons; collinear grouping inert (size_beams.jl:243-246).
- Demands: group envelope max |P| with max |M|, sagging/hogging separately, max(frame, shell) moments/shears (demands.jl:569-571, :675-678); `L_totals[g]` = longest member in the group (:560-561); Lb = max, Cb = min, Kx/Ky = max over group (:695-723).

### RC beams (ACI 318)
- Variables: `RCBeamSection` (b, h, bars, stirrup) from `rc_beam_catalog(:standard|:small|:large|:xlarge|:all)` (catalogs.jl:178-193) or bounds builder (:137-159); T-beams via `size_tbeams` when `include_flange` with per-web flange width ACI 318-11 §8.12.2 (size_beams.jl:1471-1476).
- Objective: gross b·h only (checker_objectives.jl:20-63); MinWeight returns kN, MinCost = volume proxy; rebar not counted.
- Checks (`is_feasible`, checker_strength.jl:278-350): depth; φMn ≥ Mu; φMn_neg ≥ Mu_neg; shear φ(Vc+Vs,max) with signed Nu (Eq. 11-4/11-8, §11.4.7.9); εt ≥ 0.004 (§10.3.5); As,min (§10.5.1); torsion adequacy (§11.5.3.1) if Tu > Tth; story-shell deflection (§9.5.2). Joists: §8.13.2–§8.13.6 limits, §8.13.8 10% Vc increase (joist_construction.jl:78-138).
- T-beam `uniform_geometry`: batches all ribs (and all girders) together with envelope flange inputs: `hf = minimum`, joist spacing `maximum`, flange width `minimum` across the batch (size_beams.jl:1456-1476) — conservative for each member. (Whether the batch is forced to ONE section depends on `n_max_sections` in `size_tbeams` — inferred, tbeams.jl:171.)
- RC beams NLP path exists (`rc_beams_nlp.jl`) — not traced.

## How member results feed back into slab design
1. Flat plate, within slab loop: column c1/c2 from P-M directly change moment distribution (EFM stiffness), punching b0, `ln`, and edge-beam βt (iteration.jl:513-536, :760-801).
2. Flat plate, member stage: `_reconcile_columns!` → `check_flat_plate_columns!` → `_harmonize_columns!` grow columns; `_stale_flat_plate_slabs` (graph_builder.jl:340-343) flags slabs whose stored checks used a smaller column; those slabs are re-designed by `_isolated_floor_outcome` and committed, supports merged with `_support_beats` (largest footprint not shrinking either side), then `sync_asap!`, reconcile, harmonize again (graph_builder.jl:382-398). Hard error if not settled.
3. Beam-based floors with story shell: column sections are rotational springs in the shell; beam stiffness sets shell beam demands; slab bars on those stories come from the shell solved at the final sections (member_iteration.jl:380-395).
4. Walls/row F: wall thickness jump or new frame floors → full member stage re-run → (flat path) slabs can go stale again (pipeline_spec.jl:166-195).

## Anomalies found while reading (not size-loops, but relevant)
- **Steel `MemberDemand` Cm default (SAFETY — please confirm):** `MemberDemand` defaults `M1 = 0, M2 = Mux` and the docstring calls this "conservative single-curvature, Cm = 0.6" (SS/members/types/demands.jl:77-78, :97-100). Per AISC 360-16 Eq. A-8-4 as implemented (SS/members/codes/aisc/generic/moment_amplification.jl:12-16, :34-44), single curvature is M1/M2 = −1 → Cm = 1.0; M1 = 0 gives Cm = 0.6, which is less conservative. The building steel column path builds demands without M1/M2 (SS/members/optimize/api/columns.jl:241-248), so B1 uses Cm = 0.6 for every compressed steel column/beam. (RC uses signed FEA end moments; the RC positional adapter uses M1 = −M2 correctly, columns.jl:356-361.)
- **Reconcile over-growth of rectangular columns:** `_reconcile_columns!` grows when `sqrt(Ag_req) > c1 || > c2` (column_reconciliation.jl:297-299), i.e. compares each side to the side of an equal-area SQUARE. For a 12×24 column with Ag_req = 200 in², sqrt = 14.1 > 12 → grows although Ag = 288 ≥ 200; `grow_column_for_axial!` non-square branch then sets c1 = max(c1, 14.1) → 14.5×24 (SS/slabs/codes/concrete/flat_plate/utils/column_growth.jl:309-318). Square columns (default `shape_constraint = :square`) are unaffected.
- **Steel harmonization copies volumes across lengths:** `_harmonize_steel_group!` copies the governing column's `volumes` (area × ITS length) onto every column in the group (member_iteration.jl:143), so reported steel quantity for shorter/longer columns in the group is wrong (reporting, not stiffness).
- **`collinear_grouping` is inert** (see Columns › Grouping).
- **Memo key docstring mismatch** (cache.jl:17-22 vs model.jl:163-174).

---

# TOP 5 by size impact

1. **Flat-plate column growth ratchet across slab ↔ column rounds (HIGH)** — slab loop per-dim `max(c_span_min, c_pm, c_old)` (column_updates.jl:108-109), reconcile axial growth (column_reconciliation.jl:290-304), full-load "covers current size" constraint (flat_plate_column_check.jl:462, :636-637), stacking lower ≥ upper (:492-551), support envelope `_support_beats` (graph_builder.jl:448-452). No step ever shrinks a column, and columns grown under an early thin-slab state persist after the slab thickens. Fix direction: re-pick from scratch inside each round; enforce monotonicity only on the outer handshake.
2. **Uniform column harmonization by independent max(c1), max(c2) / max steel area (HIGH when enabled)** — member_iteration.jl:72-73, :110-127; also cohort flooring in row F (interactive_checks.jl:848-876). Produces envelope sections larger than any member's own pick, then feeds stiffness back (more moment attracted). Fix: size the uniformity group jointly in the MIP (shared variable) with all members' demand sets.
3. **Row-F section floors and story-shell `section_floor` never relax and are objective-sorted (HIGH)** — interactive_checks.jl:903-920, size_beams.jl:1013-1014, :980-983; story-shell rounds 2–3 have no trim (size_beams_story_shell.jl:200-216). Fix: store floors as demand rows (capacity requirements) and/or recompute from scratch each round; allow a final relax/trim pass.
4. **RC objectives ignore reinforcement (MED-HIGH, carbon/cost)** — checker.jl:536-624, checker_objectives.jl:20-63: MinCarbon/MinCost pick the smallest Ag with any bar layout (ties broken arbitrarily by `argmax`, model.jl:331-332), favouring heavily reinforced small sections; reported rebar can be far above the lightest feasible layout at that Ag. Fix: include As·ρ_steel·ecc_steel in the coefficient, or a lexicographic tiebreak on As.
5. **Group envelope demands (MED)** — max |P| with max |M| across all pattern cases and all members of a group, Lb max / Cb min / K max, L = longest member (demands.jl:560-561, :675-723); T-beam batch flange envelope (size_beams.jl:1465-1476). Conservative by construction; matters most for framing-level joist groups (one section per level) and harmonized columns. RC columns already also check per-case rows, which only adds constraints. Fix: check each member's own geometry/demands against the shared section instead of an artificial worst-case composite.

(Honourable mention: rectangular-column reconcile over-growth — see Anomalies; small population but pure waste.)

