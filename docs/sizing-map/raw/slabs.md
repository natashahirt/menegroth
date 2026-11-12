# Slab sizing map — iterative loops and decision space

Scope: `StructuralSizer/src/slabs/**` (all slab types). Paths below are relative to
`StructuralSizer/src/slabs/` unless prefixed. Abbreviation: `FP/` =
`codes/concrete/flat_plate/`. Line numbers are from the working tree
on 2026-11-11. Status: COMPLETE (Part A, Part B, Top 5).

Shared helpers (outside slabs/): `StructuralSizer/src/iteration.jl:18` `growth_steps`,
`:35` `monotone_budget(requested, span; ceiling=48) = max(requested, min(span, 48))`,
`:56` `settle!`. `FP/utils/helpers.jl:110` `round_up_thickness` (ceil to increment).

## Part A — decision space per slab type

Dispatch: `sizing.jl:35-111` `size_slabs!` → `size_slab!` `:158-190` → `_size_slab!(::FloorType)`.
Implemented: FlatPlate `:327`, FlatSlab `:372`, CompositeDeck `:517`, OneWay `:682`,
TwoWay `:723`, Vault `:778`. Every other system throws `UnsupportedFloorSystemError` (`:239-247`).

### Flat plate (FlatPlate; DDM / EFM / FEA) — `FP/pipeline/iteration.jl`
- Variables: slab `h` (0.5" grid, `h_increment` `:19`; floor = ACI min Table 8.3.1.1 / 318-11 Table 9.5(c) on longer axis span `:65-69,116-123`, fire ACI 216.1 Table 4.2 `:125-130`; cap `ln/10` `:385`); column `c1,c2` (0.5" `size_increment`, `optimize/core/options/concrete.jl:121`, `:square` default `:119`, max 30" `options.jl:328`); punching reinforcement (studs/stirrups/caps/capitals, `opts.punching_reinforcement` default `:headed_studs_generic` `options.jl:327`) — only used when strategy ≠ `:grow_columns` (default `options.jl:326`) or `:joint_search` with `joint_studs` (`options.jl:339`); strip rebar (closed-form `select_bars` per strip with `max_bar_spacing(h)`, `FP/design/reinforcement.jl:434`; `opts.bar_size=5` sets d, `options.jl:317`); transfer bars §13.5.3; integrity bars §13.3.8.5.
- Candidate generation: h — ascending scaled scan (`thickness_jump.jl:124-172`) or blind +0.5"; columns — catalog P-M (`size_columns`) then `max(old, pm, span/15 if enabled)`; punching — linear scan from `solve_column_for_punching` direction (`punching_resolution.jl:167-214`); `:joint_search` — full (h × per-column size × studs) scan (`joint_search.jl`).
- Objective: greedy feasibility (first passing) except `:joint_search` (min `material_objective`, `joint_search.jl:20-36`) and `size_flat_plate_optimized` (grid).
- Check order and lever: Phase A — analysis → column P-M (grow columns) → two-way deflection primary/secondary (ACI 318-11 §9.5.3 / 318-19 §24.2) → one-way shear (frame strip, walls, secondary; §11.2/§22.5) → flexural tension-control (§21.2.2) → transfer section §13.5.3 ⇒ grow `h`. Phase B — re-analysis → P-M ⇒ grow columns → wall-reaction punching §11.11.1.2 ⇒ grow `h` → column punching §11.11.7.1 / PCA EB712 Fig 16-13 ⇒ per strategy grow columns / add reinforcement / grow `h` last. Phase C — primary/secondary strip rebar adequacy, secondary one-way shear on inner depth, transfer reinforcement ⇒ `h += 0.5"`; wall bar anchorage §12.12.1 ⇒ fail (no lever).
- RuleOfThumb method: single pass at ACI min, no bumps (`FP/design/rule_of_thumb.jl:24`, `iteration.jl:37-43`).

### Flat slab with drop panels (FlatSlab) — same pipeline + `drop_panel`
- Extra variables: `h_drop` ∈ {2.25, 4.25, 6.25, 8.0}" lumber (`sizing.jl:470-490`), extents `a1,a2 ≥ l/6` (ACI 8.2.4); both only enforced at minima, never driven by checks (`iteration.jl:137-170,474-505`). Min h uses FlatSlab row (`iteration.jl:118-120`).
- Punching: two sections — drop-edge in slab depth (failure ⇒ `h += 0.5"`, `punching_resolution.jl:64-67`) and column face in drop depth (studs/stirrups limited by drop reach `:369-374`; caps/capitals disallowed `:366-368`).
- Thickness scaling and `:joint_search` disabled for drop panels (`thickness_jump.jl:53`) ⇒ greedy +0.5" steps throughout.

### Two-way slab with beams (TwoWay)
- Variable: `h` only, ACI 318-11 §9.5.3.3 with αfm unknown → conservative bound (`min_thickness.jl:198-203`), c-c spans, round up 0.5" (`codes/concrete/sizing.jl:250-283`). No strength checks, no loop. Analysis method only recorded (`assign_panel_analysis!` `sizing.jl:746`).

### One-way slab (OneWay)
- Variable: `h` only, ACI 318-19 Table 7.3.1.1 by thickest support condition among cells, cantilever override at openings (`sizing.jl:682-712`). No loop, no bars.

### Waffle / ribbed (Waffle)
- StructuralSizer: `_size_span_floor(::Waffle)` picks form depth from {8..24}" ≥ min, fixed 40% voids (`codes/concrete/sizing.jl:318-348`); no `_size_slab!(::Waffle)` dispatch.
- Solid heads: grown one module at a time until punching/rib-web/rib-shear pass (loop lives in `StructuralSynthesizer/src/analyze/slabs/slabs/solid_head_check.jl:346-381`). Rib geometry (width, spacing, depth) is not a design variable in any loop found.

### Composite deck (CompositeDeck)
- Variables: total depth (tabulated) × gage; profile fixed. Exhaustive, min self weight (`codes/steel/deck_floor.jl:198-223`). Checks: SDI §2.4.B.6 minimums, unshored span, web crippling, Mno/Ω, shear, deflection.

### Vault (Vault)
- Variables: rise (λ ∈ [10,20]) and thickness (2–4") — grid/Ipopt optimization (`optimize/api.jl:243-330`) or fixed rise + thickness bisection on 5 mm grid (`codes/vault/haile_unreinforced.jl:774-818`). Checks: stress, kern, elastic-shortening rise loss.

### Timber (CLT/DLT/NLT/MassTimberJoist), HollowCore, NonCompositeDeck, JoistRoofDeck, PTBanded
- Not implemented — throw `UnsupportedFloorSystemError` (see final record).

## Part B — loop records (appended as verified)

### FP outer loop (A → B → C restart)
- location: `FP/pipeline/iteration.jl:437-1151`, `_size_flat_plate!` (`for outer in 1:outer_budget`)
- decision variables: slab thickness `h` (restart floor); columns `c1,c2` carried across restarts.
- inputs / outputs: initial `h` = max(ACI min thickness Table 8.3.1.1 / FlatSlab row (`:116-123`), fire min ACI 216.1 (`:125-130`)) or `opts.min_h`; feeds final `result` (slab + column sizes + rebar + studs) to `size_slabs!`/StructuralSynthesizer.
- stop rule + budget + step: returns on Phase C success (`:1150`); budget `monotone_budget(max_iterations=10, _thick_steps())` (`:437`), `_thick_steps` = half-inch steps from current h to `h_max = ln/10` (`:385-387`). Restart triggers: Phase B h bump (`:1088-1097`) or Phase C `needs_more_depth` → `h = round_up_thickness(h + h_increment)` (+0.5", `:1137-1147`, NOT the scaled jump).
- monotone? Yes: h only grows; columns never shrink (`FP/pipeline/column_updates.jl:108-109` `max(c_span_min, c_pm, c_old)`); no reset of columns on restart.
- order dependence: Phase A checks run before punching; Phase B growth happens at Phase-A h; Phase C rebar failure triggers restart after columns already grown in B.
- cost per pass: full Phase A + B + C (each with ≥1 moment analysis — DDM closed form, EFM frame solve, or FEA shell solve).
- size impact: **HIGH** — columns grown by Phase B at a thinner h are retained when h later rises (Phase B wall/drop bump or Phase C section-inadequate), so final columns can be sized for punching at a thinner slab than the one installed. Phase C restart uses +0.5" blind step, then Phase A may jump again.
- speed impact: MED (restarts are rare but re-run the whole A/B with fresh analysis).
- opportunities: on restart, reset columns to `c_floor` (P-M/initial size) and re-derive punching sizes at new h; fold Phase C strip-section adequacy (`design_strip_reinforcement(...).section_adequate`) into `phase_a_depth_passes` so it uses the scaled jump instead of +0.5" restarts (the joint search already does this, `FP/pipeline/joint_search.jl:142-164`).
- confidence: verified-by-reading

### FP Phase A — depth convergence
- location: `FP/pipeline/iteration.jl:447-731`, `_size_flat_plate!` (`for iter_a in 1:a_budget`)
- decision variables: `h` (and column `c1,c2` via P-M, and drop `h_drop`/extent via ACI re-check).
- inputs / outputs: `h`, column sizes, `Pu` (recomputed when h changes, `:465-471`), drop geometry; outputs converged `h`, `moment_results`, `secondary_results`, `column_result` to Phase B.
- stop rule + budget + step: break when all checks pass (`:726-730`); budget `monotone_budget(10, _thick_steps())` (`:447`); hard abort `h > ln/10` (`:453-456`). Step: `_jumped_depth` (`:313-336`) → `propose_slab_thickness` (`FP/pipeline/thickness_jump.jl:147-172`): thinnest 0.5" candidate passing all Phase-A checks on scaled demands; falls back to +0.5" when scaling refused (drop panel, pattern loading, h-dependent edge-beam βt, `thickness_scale_applies` `thickness_jump.jl:51-57`).
- check order (first failure decides): A1 analysis (`:524-550`) → A2 column P-M `size_columns` + `_update_column_sizes!` (`:563-599`; any column change >5% `column_tol` → `continue` re-analysis, h unchanged) → A3 two-way deflection primary (ACI 24.2 / 318-11 §9.5.3, `:611-628`) → A3b secondary deflection (`:632-648`) → A4 one-way shear (frame strip + wall + secondary, §22.5/11.2, `:664-681`) → A5 flexural adequacy tension-controlled (ACI 21.2.2, `:685-707`, primary then secondary) → A6 §13.5.3 transfer section (`:712-723`). Every slab failure → grow h. P-M failure → grow columns.
- monotone? Yes: h only via jump/increment upward; columns via `max(...)` (`column_updates.jl:108-109`).
- order dependence: Column P-M runs first, so columns are grown for the moments at the *current (thin) h*; a later h jump increases self-weight/Pu and may require yet bigger columns, but never allows smaller ones. Because the jump scans all Phase-A checks jointly, the slab-check order doesn't change the chosen h when scaling applies; when it doesn't (drop panels etc.) the order only affects iteration count.
- cost per pass: one full moment analysis (primary + secondary; FEA = shell re-solve with cache, `analysis_cache` `:232-251`) + column P-M catalog/NLP + closed-form checks; jump candidates are closed-form on scaled results.
- size impact: **MED** — 0.5" increments are fine; but (a) drop-panel / pattern-loading / edge-beam slabs fall back to blind +0.5" steps (no overshoot but slow), (b) P-M-driven column growth at each intermediate h is irreversible, (c) h_drop re-check only raises (`:480-483`).
- speed impact: HIGH for FEA (each column change or non-scaled h step = full shell re-analysis; budget up to 48).
- opportunities: allow scaling for drop panels (drop self-weight is a separate known pressure, `drop_panel_dead_pressure` `FP/utils/calculations/drop_panels.jl:40`); for pattern-loaded results scale each pattern separately; settle column P-M only after h converges (columns are a weak function of h) to avoid interleaved re-analyses; bisection on h when scaling unavailable.
- confidence: verified-by-reading

### FP thickness jump (candidate scan)
- location: `FP/pipeline/thickness_jump.jl:124-172`, `_thickness_candidates`, `propose_slab_thickness`; caller `FP/pipeline/iteration.jl:313-336` `_jumped_depth`
- decision variables: `h` ∈ {0.5" grid above current h, ≤ ln/10}.
- inputs / outputs: one analysis at h0; scales demands by `r = qu(h)/qu(h0)` and gross deflection by `r·(h0/h)^3` (`:159-166`, loads via `loads_at_thickness` `:35-39`); outputs next h for Phase A (or Phase B punching=true).
- stop rule + budget + step: first passing candidate (linear ascending scan); none → last+0.5" (past h_max, aborts loop).
- monotone? Yes (candidates strictly above h).
- order dependence: none within the scan (all checks AND-ed via `phase_a_depth_passes` `:242-301` and optionally `punching_depth_passes` `:342-376`).
- cost per pass: closed form per candidate (deflection Ie, shear, flexure, transfer); no re-analysis.
- size impact: LOW — picks thinnest passing grid point under frozen column sizes; slight risk of over-shoot because column stiffness/sizes are frozen (stiffer columns from later P-M would reduce slab moments only for DDM-insensitive cases).
- speed impact: LOW (cheap) — saves many full re-analyses.
- opportunities: binary search instead of linear scan (checks monotone in h); extend applicability (drop panels, pattern loading).
- confidence: verified-by-reading

### FP column P-M fixed point (inside Phase A and B)
- location: `FP/pipeline/iteration.jl:563-599` (A) and `:804-840` (B); `_update_column_sizes!` `FP/pipeline/column_updates.jl:90-138`
- decision variables: column `c1,c2` and section/bars.
- inputs / outputs: `Pu` (slab tributary, self weight at h), `Mu`/`Mu_secondary` from analysis × §13.6.9.2 distribution (`iteration.jl:275-293`); P-M cache `_col_cache` built once (`:202-219`). Feeds stiffness of next analysis.
- stop rule + budget + step: stops when no column changes by > `column_tol=0.05` relative (`column_updates.jl:128-131`); step = catalog next section (discrete) or NLP; shares Phase A/B budget.
- monotone? Yes, `max(c_span_min, c_pm, c_old)` (`column_updates.jl:108-109`); if held larger than catalog, bars redesigned (`:114-125`).
- order dependence: runs before every slab check in A, before punching in B.
- cost per pass: catalog P-M check (cached) + full slab re-analysis on change.
- size impact: MED — never shrinks; stiffer columns attract more unbalanced moment → more P-M demand → ratchet. Also start size `span/15` (`column_updates.jl:37-40`, `estimate_column_size_from_span` `FP/utils/calculations/deflection.jl:333`) is a floor that can exceed P-M need.
- speed impact: MED-HIGH under FEA (each change = re-analysis).
- opportunities: cap ratchet by allowing shrink to `c_pm` after convergence and one confirm pass; damp with `column_tol`; reuse FEA factorization when only column stub stiffness changes.
- confidence: verified-by-reading

### FP Phase B — punching resolution loop
- location: `FP/pipeline/iteration.jl:750-1086` (`for iter_b in 1:b_budget`)
- decision variables: column `c1,c2`; studs/stirrups/caps/capitals per `opts.punching_reinforcement`; h (last resort).
- inputs / outputs: Phase-A h; re-runs analysis each pass (`:771-797`), P-M (`:804-840`), punching per column (`:853-877`, ACI 318-11 §11.11.7.1 / PCA EB712 Fig 16-13 cited `:850-852`), wall-reaction punching §11.11.1.2 (`:879-920`). Outputs `punching_local`, column sizes to Phase C.
- stop rule + budget + step: break when all punching OK (`:1018-1025`) or studs resolve without growth (`:1083-1085`); `b_budget = monotone_budget(10, _column_steps())` (`:750`, steps from c to `opts.max_column_size` at `size_increment`). Step: see "punching resolver". h step on wall failure: `_jumped_depth(...; punching=true)` (`:913`); on levers exhausted: `_jumped_depth(h_before_punch, ...; punching=true)` (`:1069`).
- monotone? Yes — columns only grow (resolver + `_update_column_sizes!`), h only grows.
- order dependence: (1) P-M growth precedes punching (`:835-840`). (2) Wall punching checked before column punching; a failing wall forces h jump even if columns are fine (`:892-919`). (3) Failures classified interior first then edge/corner (`:923-940`) and resolved in that order; resolver returns on the first column it can't fix (`punching_resolution.jl:105-109,124-126,134-137`) — columns already grown earlier in the same pass keep their new size although h is about to rise.
- cost per pass: full moment analysis + P-M + closed-form punching. Re-analysis after any column growth (stiffer column attracts more moment).
- size impact: **HIGH** — default `:grow_columns` greedily grows columns (cost of column concrete over story height) instead of considering a thicker slab or studs; growth retained if h later bumps; the drop-edge failure (`punching_resolution.jl:64-67`) bumps h only +0.5" per outer pass and for drop panels the jump is unscaled.
- speed impact: HIGH under FEA (each growth = re-analysis).
- opportunities: `:joint_search` (below) is the fix — make it default; otherwise reset already-grown columns when returning `(true, h)`; analytic Vu/Mub sensitivity to column stiffness to avoid re-analysis confirm passes.
- confidence: verified-by-reading

### FP punching resolver (per-column size scan)
- location: `FP/pipeline/punching_resolution.jl:46-143` `_resolve_punching_failures!`; `_column_candidates` `:167-191`; `_grow_to_passing!` `:200-214`; target `solve_column_for_punching` `FP/utils/column_growth.jl:157-218`
- decision variables: per column `c1,c2` (grid `column_opts.size_increment`), reinforcement design.
- inputs / outputs: fixed demand Vu/Mub/Muy from current analysis; `recheck(i)` = closed-form punching. Outputs grown columns / reinforcement entries, or h+0.5".
- stop rule + budget + step: linear scan along direction toward analytic target `b0_req = b0·ratio` (`column_growth.jl:166`), stepping `inc`, past target up to `c_max` (`punching_resolution.jl:177-189`); first passing candidate kept.
- monotone? Yes — `max(c, col.c1, col.c2)` (`column_growth.jl:174,185,203-204`); `_enforce_aspect_ratio!` grows the smaller side (`:226-237`).
- order dependence: strategies: `:reinforce_first` (studs first, `:92-110`), `:reinforce_last` (grow then studs, `:112-127`), `:grow_columns` (default, no studs, `:129-138`). First-failing column ordering matters (see Phase B).
- cost per pass: closed form; cheap.
- size impact: MED — `:square` shape forces both dims up (`:181-182`); rounding up to `inc`; `:grow_columns` never considers studs even if far cheaper.
- speed impact: LOW.
- opportunities: bisection on k; cost-ranked choice between size and studs (as in joint search `joint_search.jl:178-235`).
- confidence: verified-by-reading

### FP :joint_search (thickness × columns × studs)
- location: `FP/pipeline/joint_search.jl:256-321` `joint_search`; `joint_thickness_scan` `:59-85`; `_joint_column_option` `:178-235`; invoked from `FP/pipeline/iteration.jl:943-1016`
- decision variables: h ∈ {h0} ∪ 0.5" grid up to ln/10 (only h0 if `opts.punching_thickening=false`, `:258-260`); per column size ≥ `c_floor` (sizes at Phase-A exit, `iteration.jl:416`) and optional headed studs.
- inputs / outputs: one analysis at h0, scaled per candidate (`:262-271`); objective `material_objective` (volume/weight/carbon/cost, `:20-36`) = slab concrete + strip rebar volume (`:277-293`) + column story concrete+steel (`:112-118`) + `stud_weight`×stud shank steel (`:224-226`). Output `best` → sets h/columns; confirm with a real analysis (`iteration.jl:1006-1010`).
- stop rule + budget + step: ascending scan with lower-bound prune `concrete_term(h)` (`:66`, `:273-275`); tie within 1% prefers preferred (floor-above) sizes (`:10`, `:82-84`). Confirm loop: Phase B iterations rerun scan until confirmed.
- monotone? Columns never below `c_floor` / installed sizes (`iteration.jl:976`); h ≥ h0. Per-column option scan breaks when column cost ≥ best (`:212`).
- order dependence: none for slab checks (AND-ed); per-column options independent (column interaction via moment redistribution ignored until confirm).
- cost per pass: closed form per (h, column, size) + one analysis per confirm.
- size impact: LOW — globally cost-ranked; residual: `c_floor` includes Phase A P-M growth at thinner h; lower bound ignores columns so prune is safe. Applies only when `thickness_scale_applies` (`iteration.jl:884-885`), i.e. NOT for drop panels/pattern loading/edge-beam-from-h — those fall back to the greedy resolver.
- speed impact: LOW-MED.
- opportunities: extend scaling to drop panels so joint search covers flat slabs; allow c_floor to drop to pure P-M requirement at each candidate h; include drop depth/extent as a variable.
- confidence: verified-by-reading

### FP Phase C — final design / rebar (restart trigger)
- location: `FP/pipeline/final_design.jl:40-330` `_run_final_design`; restart at `FP/pipeline/iteration.jl:1137-1147`
- decision variables: strip rebar (bar size/spacing), transfer bars (§13.5.3), integrity bars (§13.3.8.5); h (via restart).
- inputs / outputs: final moments (EFM face-of-support §13.7.7.1 `:55-60`; FEA strip/area extraction `:88-133`); `needs_more_depth=true` on primary section inadequate (`:143-151`), secondary inadequate (`:240-248`), secondary one-way shear on inner depth (`:252-265`), transfer (`:280-288`). Wall bar anchorage §12.12.1 fails without thickening (`:292-324`).
- stop rule + budget + step: single pass; failure → outer loop, h += 0.5".
- monotone? Yes.
- order dependence: primary rebar → secondary rebar → secondary shear → transfer → anchorage; first failure restarts with full Phase A/B.
- cost per pass: closed form for DDM/EFM; FEA area/strip extraction from cached model.
- size impact: MED — FEA direct design moments can exceed the frame-strip moments used in Phase A (Phase A shear uses frame strip, `iteration.jl:652-654`), so restart grows h only in 0.5" blind steps and keeps all grown columns.
- speed impact: MED.
- opportunities: run the same FEA-extracted adequacy within Phase A jump candidates; use scaled jump on restart.
- confidence: verified-by-reading

### FP drop panel geometry re-check (flat slab)
- location: `FP/pipeline/iteration.jl:137-170` (setup) and `:474-505` (each Phase A iter); `auto_size_drop_depth` `sizing.jl:477-490`; initial geometry `sizing.jl:~440-467`
- decision variables: `h_drop` ∈ STANDARD_DROP_DEPTHS {2.25, 4.25, 6.25, 8.0}" (`sizing.jl:475`); extents `a1,a2 ≥ l/6`.
- inputs / outputs: h; feeds Pu, analysis, punching at drop edge/face.
- stop rule + budget + step: rule-based, ACI 8.2.4(a) h_drop ≥ h/4, 8.2.4(b) a ≥ l/6 (cited `iteration.jl:135-136`); only increases.
- monotone? Yes (only resized when below minimum).
- order dependence: punching failure at drop edge → h +0.5" (`punching_resolution.jl:64-67`), never deeper/wider drop. Drop depth/extent are NOT design variables driven by any check.
- cost per pass: trivial.
- size impact: MED — drop depth is set by lumber table from h, not by punching/deflection demand; a punching failure at the drop edge thickens the whole slab instead of enlarging the drop extent.
- speed impact: LOW.
- opportunities: treat drop extent and h_drop as joint-search variables; for drop-edge failure grow `a_drop` first (cheaper concrete).
- confidence: verified-by-reading

### FP shear cap / column capital projection scan
- location: `FP/studs/shear_caps.jl:146-153` `design_shear_cap`; `FP/studs/column_capitals.jl:70-77` `design_column_capital`
- decision variables: `h_cap` (cap depth = cap extent for shear caps, `:135-136`; capital flare).
- inputs / outputs: Vu, Mub, Muy at current column; cap: two sections (column face at d+h_cap and cap edge, §13.2.6/§11.11.1.2); capital: enlarged support §13.1.2. Called from `_try_reinforcement` (`FP/pipeline/punching_resolution.jl:318-338`) with `max_projection = h` for caps.
- stop rule + budget + step: `while h_cap <= max_proj` step `h_increment=0.5"`, first passing returned.
- monotone? yes (linear ascending).
- order dependence: only used under `:reinforce_first`/`:reinforce_last` with those reinforcement types; not with drop panels (`punching_resolution.jl:366-368`).
- cost per pass: closed form.
- size impact: LOW (thinnest passing 0.5" step; extent tied to depth = conservative coupling).
- speed impact: LOW.
- opportunities: decouple extent from depth; bisection.
- confidence: verified-by-reading

### Headed studs / closed stirrups design
- location: `FP/utils/calculations/shear_studs.jl:135-320` `design_shear_studs`; `FP/studs/closed_stirrups.jl`; outer section `FP/studs/outer_section.jl`
- decision variables: n_rails (from geometry, `:264`), stud spacing `s = min(s_reqd, s_max)` with `s_max = 0.5d / 0.75d` (§11.11.5.2, `:280-281`), number of lines (extended until outer section d/2 beyond passes, §11.11.5.4 cited `punching_resolution.jl:289-291`).
- stop rule: closed form + line extension; no h/column interaction.
- size impact: LOW. speed: LOW. opportunities: none significant.
- confidence: inferred (spot-read lines cited; line-extension loop not read in full)

### EFM Hardy Cross moment distribution
- location: `FP/analysis/efm/moment_distribution.jl:221-291` (`for iter in 1:max_iterations`, default 20, tol 0.01 `:67`)
- decision variables: none (analysis); joint moments.
- stop rule: `max_change < tolerance` (absolute, in moment units) or 20 iterations — no non-convergence flag.
- cost: O(members) per iter, cheap. Alternative `method.solver == :asap` path uses an EFM frame with `EFMModelCache` (`FP/pipeline/iteration.jl:236-237`).
- size impact: LOW (could under-converge silently for many spans → small moment error either direction).
- speed impact: LOW.
- opportunities: direct stiffness solve (small linear system) instead of iterative distribution; warn on budget exhaustion.
- confidence: verified-by-reading

### FEA model rebuild vs update (per sizing pass)
- location: `FP/analysis/fea/precompute.jl:112-190` `_build_or_update_fea!`; key `FP/analysis/fea/cache.jl:160-185` `fea_mesh_key`; `acquire_fea_cache!` `:196-204`
- decision variables: none (analysis cost driver).
- behavior: mesh key includes every column's `c1,c2`, shape, drop-panel `h_drop,a1,a2` (`cache.jl:169-182`). Any column growth (Phase A P-M or Phase B punching) or drop resize ⇒ full remesh + rebuild (`precompute.jl:136-141`); h/E changes take the cheaper update path. Mesh refinement edge around columns is `clamp(min_col_dim/2, 0.04 m, target/2)` (`FP/analysis/fea/model.jl:348-361`), so column size also changes mesh density. D/L split solves per build (`precompute.jl:183-188`).
- size impact: LOW directly; indirectly mesh-dependent peak moments can differ between passes (non-monotone demand), which combined with grow-only variables locks in the worst pass.
- speed impact: **HIGH** — FEA is the fallback whenever DDM/EFM inapplicable (`FP/utils/helpers.jl:765-817`), and every column step re-meshes.
- opportunities: model column growth as patch-stiffness change on a fixed mesh (rigid patch radius from max allowable c); batch all column growth into one confirm; reuse factorization when only h changes (already update path).
- confidence: verified-by-reading

### FEA section-cut adaptive bandwidth
- location: `FP/analysis/fea/bandwidth.jl:155-203` `_adaptive_bandwidth` (tol 5%, max_iter 6, √2 geometric step); called only as verbose diagnostic `FP/analysis/fea/run.jl:214-216`.
- size/speed impact: LOW / LOW (diagnostic only).
- confidence: verified-by-reading

### Analysis-method fallback (DDM/EFM → FEA / area shell)
- location: `FP/utils/helpers.jl:765-817` `resolve_analysis_method`; called once at `FP/pipeline/iteration.jl:103-109`
- decision variables: analysis method (DDM §13.6.1, EFM §13.7 applicability; openings §13.4.1–13.4.2 → area shell `panel_shell()`; irregular panels → area shell `:786-789`).
- stop rule: one-shot, before sizing; not re-evaluated as columns grow (column size enters some DDM limits only indirectly).
- size impact: MED — DDM/EFM vs FEA give different demands; FEA path also disables thickness scaling when pattern loading is enveloped (`thickness_jump.jl:54`) → blind +0.5" steps, and joint search unavailable.
- speed impact: HIGH (FEA path ×re-meshes).
- opportunities: cache applicability per layout (already a single call); allow scaling per pattern case.
- confidence: verified-by-reading

### Pattern loading
- location: `FP/utils/helpers.jl:713-735` `check_pattern_loading_requirement` (ACI 318-11 §13.7.6, L/D > 0.75) — warn-only for DDM; EFM/FEA set `pattern_loading` on results (FEA-native via D/L split, `precompute.jl:100-108`).
- loop: none; but `pattern_loading=true` disables `thickness_scale_applies` (`FP/pipeline/thickness_jump.jl:54`) → Phase A falls back to +0.5" steps and `:joint_search` is skipped (`iteration.jl:884-885`).
- size impact: MED (via forced fallback to greedy resolver). speed: MED.
- opportunities: scale D and L pattern solutions separately (qD changes with h, qL doesn't) and re-envelope — exact for linear analysis.
- confidence: verified-by-reading

### Flat plate quick span sizing (initialization helper)
- location: `codes/concrete/sizing.jl:60-195` `_size_span_floor(::FlatPlate, ...)`; punching loop `:157-175`
- decision variables: h (column fixed at span/15, `:75`).
- stop rule + budget + step: `for _ in 1:5`, +0.5" each, interior column only, two-way punching with At = l1·l2 (no unbalanced moment). Silent `@warn` on exhaustion (`:177-179`).
- monotone? yes.
- use: `thickness_only=true` path (`:95-99`) returns ACI min only — used by preparation; full path is a quick estimate, not the design pipeline.
- size impact: LOW for final design (pipeline re-sizes), but if used to seed loads (self weight) for other members it can overestimate (punching at At = full panel incl. column area).
- speed impact: LOW.
- opportunities: closed-form solve for d from punching quadratic.
- confidence: verified-by-reading

### Flat slab span sizing / drop initial geometry
- location: `codes/concrete/sizing.jl:205-232` (`max(ceil-to-0.5", 4")` of ACI min FlatSlab); `sizing.jl:438-467` `_build_drop_panel_geometry` (h_est = l1/36, h_drop from lumber table, a = ratio·l with default 1/6).
- loop: none. size impact: LOW-MED (h_drop seeded from l1/36 estimate; pipeline only raises it).
- confidence: verified-by-reading

### One-way slab (CIP)
- location: `sizing.jl:682-712` `_size_slab!(::OneWay)`; `codes/concrete/sizing.jl:293-308`
- decision variables: h only = ACI 318-19 Table 7.3.1.1 (318-11 Table 9.5(a)) divisor by support condition (`_slab_span_support` `sizing.jl:596-605`, thickest condition among cells, `thicker_support` with user option `:583-590`); cantilever check at unframed openings (`:697-705`). Rounded up to 0.5".
- checks: NONE beyond min thickness — "Bars are not sized here" (`:680`); no flexure/shear/deflection iteration.
- loop: none. size impact: MED — thickest support condition among all cells governs entire slab (`:599-603`); spans use topping span or primary c-c span (not clear span).
- speed: LOW. opportunities: per-cell thickness or clear span; strength/deflection check allowing thinner than table with computed deflection (Table note permits).
- confidence: verified-by-reading

### Two-way slab with beams
- location: `sizing.jl:723-754` `_size_slab!(::TwoWay)`; `codes/concrete/sizing.jl:250-283`; `codes/concrete/min_thickness.jl:177-220`
- decision variables: h only (ACI 318-11 §9.5.3.3 Eq. 9-12/9-13).
- behavior: beams sized after the slab, so `alpha_fm = nothing` → ENGINEERING-JUDGMENT upper bound `max(Table 9.5(c) exterior, 1.1·Eq.(9-12)@αfm=0.2, 5")` (`min_thickness.jl:198-203`). Uses c-c spans (`codes/concrete/sizing.jl:242-244` notes this gives thicker slab). No re-sizing once beams (αfm) are known (no caller passes `alpha_fm` — grep of StructuralSynthesizer found none).
- loop: none. size impact: **HIGH** — upper bound over (a)–(d) plus c-c spans; with real beams (αfm > 2) Eq. 9-13 gives `ln(0.8+fy/200000)/(36+9β)` vs. bound ~`/36·1.1` or table ln/30-ish → systematic over-thickness, and its self weight feeds beam sizing.
- speed: LOW.
- opportunities: two-pass: size beams, compute αfm, re-run min_thickness (cheap closed form), then re-size beams with lighter slab; use clear spans.
- confidence: verified-by-reading (numeric over-thickness magnitude inferred)

### Waffle span sizing (table pick)
- location: `codes/concrete/sizing.jl:318-348` `_size_span_floor(::Waffle)`
- decision variables: total depth from STANDARD form depths {8,10,12,14,16,20,24}" ≥ `min_thickness(Waffle(), ln)`; fixed void ratio 0.40.
- loop: first table depth ≥ minimum. Coarse 2–4" steps. No rib geometry variables, no strength checks here.
- size impact: MED (coarse form steps; fixed void ratio). speed: LOW.
- confidence: verified-by-reading. Note: no `_size_slab!(::Waffle)` in `sizing.jl`, so waffle goes through StructuralSynthesizer paths (below).

### Waffle solid-head growth (grillage)
- location: `StructuralSynthesizer/src/analyze/slabs/slabs/arrangement_heads.jl` `resolve_arrangement_heads` (`while true`); step `StructuralSizer` `grow_checked_column_head` / `grow_column_head` `codes/concrete/waffle/solid_head_modules.jl` (whole bays; "The set only grows"). The rectangle corner-fraction loop (`grow_rectangle_grillage_heads`, `grown_solid_head`) is removed; a rectangle is a `modular_rib_arrangement` on the same path.
- decision variables: the bay set of each column's head. One step adds the bays across the outline edges facing the failing check's direction, or, when the check names no direction, every bay that shares a node with the head (one ring; on a rectangular grid, the next whole module).
- checks: general column punching at d/2 outside the outline with the stub's moments (`punching_check_general`), rib one-way shear at d from the face, stem hogging compression at the face (`waffle/rib_head_shear.jl`).
- stop rule + budget: until every head passes; a step that meets another head or the slab edge, or does not lower that head's ratio, marks the head stuck. Budget: one step per bay in the arrangement.
- monotone? yes (bays only added).
- order dependence: greedy, worst failing head first; one head's growth changes the others' demand, so a symmetric plan can end with unequal heads.
- cost per pass: full arrangement frame solve (`analyze_arrangement_grillage`) per trial step.
- size impact: MED — bay-sized steps, per column.
- speed impact: MED.
- opportunities: analytic punching scaling with b0 to jump directly to the needed bay count; rib depth/width not varied. The building workflow does not call this loop yet: it checks the input `solid_head` fraction without growing it (`solid_head_panel_punching`, `solid_head_frame_punching`).
- confidence: verified-by-test (`test_arrangement_heads.jl`, `test_solid_head_check.jl`)

### Composite deck (depth × gage enumeration)
- location: `codes/steel/deck_floor.jl:198-223` `size_composite_deck_slab`; candidate checks `:68-187` `deck_slab_candidate`; dispatch `sizing.jl:517-539`
- decision variables: total depth (tabulated for the profile) × gage (`_BEARING_GAGES`). Deck profile fixed by `opts.deck_profile` (not searched).
- checks (SDI C-2017 / Vulcraft ASD): f'c ≥ 3000 psi, topping ≥ 2" (§2.4.B.6), unshored construction span, web crippling (if bearing given), M ≤ Mno/Ω, shear, live L/360 and optional superimposed deflection.
- stop rule: exhaustive; `argmin` by (self weight, depth).
- monotone? n/a (global enumeration).
- size impact: LOW-MED — simple-span ASD moment `wL²/8` always (`:124`, `designed_for_continuity=false` `:185`); SDL/LL taken as max over cells (`sizing.jl:525-526`); profile not searched.
- speed impact: LOW.
- opportunities: search over profiles; continuous-span moments when n_spans>1; objective = cost/carbon (deck steel) rather than weight.
- confidence: verified-by-reading

### Vault thickness bisection (Haile analytic)
- location: `codes/vault/haile_unreinforced.jl:774-818` `_find_min_thickness`; called `:622-633`
- decision variables: shell thickness t on grid 5 mm in [t_min, t_max] (default `vopt.thickness_bounds`).
- checks: stress ≤ allowable, thrust-line kern, elastic-shortening equilibrium rise converged and rise loss ≤ limit (`:791-801`).
- stop rule: bisection over the grid assuming monotone feasibility (`:812-817`); returns t_max with warning if none pass.
- monotone? assumed (docstring `:766-768`).
- size impact: LOW. speed impact: LOW (log2 n evaluations, each with root solve).
- opportunities: none major; verify monotonic kern assumption.
- confidence: verified-by-reading

### Vault optimization (rise × thickness grid)
- location: `optimize/api.jl:243-330` `optimize_vault` → `optimize_continuous(solver=:grid, n_grid=20, n_refine=2)`; problem `optimize/problems.jl` (constraints stress, convergence, kern, `:168-190`).
- decision variables: rise (λ bounds 10–20) and thickness (2–4").
- stop rule: 20×20 grid + 2 local refinements (or Ipopt).
- size impact: LOW (global within bounds; refinement resolution limits optimality).
- speed impact: MED (≈400+ equilibrium solves).
- opportunities: for fixed rise, thickness is 1-D monotone → use `_find_min_thickness` inside a 1-D rise search.
- confidence: verified-by-reading (grid internals not opened)

### Flat plate grid optimization (alternative entry point)
- location: `optimize/api.jl:428-545` `size_flat_plate_optimized`; problem `optimize/flat_plate/problem.jl`, evaluator `optimize/flat_plate/evaluator.jl`, rebar sweep `optimize/flat_plate/rebar_evaluator.jl`
- decision variables: (h, c) continuous grid (single c for all columns), bar size ∈ {#4..#8}.
- stop rule: 20×20 grid + 2 refines; DDM only; falls back to the greedy FEA pipeline when DDM inapplicable (`:455-467`, `_optimized_fea_fallback` `:561+`).
- size impact: LOW for DDM-permitted layouts (global), but uniform c for all columns over-sizes edge/corner vs interior or vice versa.
- speed impact: MED.
- confidence: verified-by-reading (evaluator not opened)

### Timber / other unsupported systems
- CLT `codes/timber/clt.jl:20-24`, DLT `codes/timber/dlt.jl:19-22`, NLT `codes/timber/nlt.jl:19-23`, mass timber joist `codes/timber/mass_timber_joist.jl:19-23`, hollow core `codes/concrete/hollow_core.jl:20-23`, non-composite deck `codes/steel/non_composite_deck.jl:15-17`, joist roof `codes/steel/joist_roof.jl:19-22`, PT banded `codes/concrete/sizing.jl:357-358`: all `throw(UnsupportedFloorSystemError)`. No sizing loops exist.
- confidence: verified-by-reading

## Top 5 by size impact

1. **Two-way slab with beams uses an αfm-unknown upper bound and is never revisited** (`codes/concrete/min_thickness.jl:198-203`, `sizing.jl:723-754`, c-c spans `codes/concrete/sizing.jl:242-244`). Every two-way slab is sized as if the beams were absent (Table 9.5(c) exterior or 1.1·Eq. 9-12 at αfm=0.2), and that self weight then loads the beams. Fix: re-run `min_thickness` with the real αfm after the beams are sized, and use clear spans.
2. **Flat plate default `:grow_columns` greedy punching** (`FP/pipeline/punching_resolution.jl:129-138`, default `options.jl:326`). Columns grow first and a thicker slab or studs are never compared on cost. Columns grown earlier in the same pass are kept when a later column forces an h bump (`:134-137` returns after mutating earlier columns). Fix: make `:joint_search` the default and reset the grown columns on an h bump.
3. **Grow-only columns carried across h restarts** (`FP/pipeline/column_updates.jl:108-109`, outer loop `FP/pipeline/iteration.jl:1088-1097,1137-1147`). Columns sized for punching or P-M at a thinner slab are never shrunk once h rises, either from a Phase B wall or drop bump or from a Phase C section-inadequate result. Fix: on restart, reset columns to their P-M floor.
4. **Flat slabs, pattern loading and h-dependent edge-beam βt drop out of both the thickness scaling and the joint search** (`FP/pipeline/thickness_jump.jl:51-57`, `iteration.jl:884-885`). These slabs fall back to blind +0.5" steps and the greedy resolver. Drop depth and extent are fixed at the ACI minimum, so a punching failure at the drop edge thickens the whole slab instead of enlarging the drop (`punching_resolution.jl:64-67`, `iteration.jl:474-505`). Fix: scale drop self weight and the D/L patterns separately, and add drop extent and depth as joint-search variables.
5. **Coarse or rule-based picks with no strength iteration.** Waffle takes the next form depth (2–4" steps) at a fixed 40% void ratio (`codes/concrete/sizing.jl:333-341`). Waffle solid heads grow all four corners together (`StructuralSynthesizer/.../solid_head_check.jl:361-380`). One-way slabs take the thickest support condition over all cells (`sizing.jl:596-605`). Composite deck always uses the simple-span wL²/8 moment (`codes/steel/deck_floor.jl:124,185`). Fix: grow each solid head separately, size per cell or with clear spans, and use the continuous-span deck moment.

Honourable mention (speed): with FEA, every column-size change re-meshes the shell model because column sizes are part of the mesh key (`FP/analysis/fea/cache.jl:169-173`, `precompute.jl:136-141`). FEA is also the automatic fallback whenever DDM or EFM is not permitted.

