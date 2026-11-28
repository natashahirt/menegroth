# Sizing map: vertical systems ⇄ floor systems interface

Scope: the interface between vertical elements (RC columns, steel columns,
ordinary RC walls (gravity and lateral), cores, grade walls) and each floor
system (flat plate, flat slab, two-way with beams, one-way incl. joists,
waffle, composite deck, vault). Read-only mapping, working tree 2026-11-11.
Paths: `SS/` = `StructuralSizer/src/`, `SY/` = `StructuralSynthesizer/src/`.
Each claim is tagged **[read]** (verified by reading the cited lines) or
**[inferred]** (deduced from call sites / names, not traced end to end).

Does not repeat the other raw reports: wall thickness jump internals, row-F
loops, P-Δ solve set, foundations (`walls-lateral-foundations.md`); flat-plate
phases A/B/C and punching resolver (`slabs.md`); member MIP/grouping
(`members.md`); stage graph (`building-pipeline.md`).

(Status: complete 2026-11-11. Folded into `plan.md` work packages 0.8 and Phase 5.)

---

## 0. Common plumbing: how a wall becomes visible to a floor

- **Wall thickness is a required user input, no default.** `params.wall_thickness`
  (`SY/design/parameters.jl:262-264`); baked at `prepare!` into every `Wall`
  (`SY/core/initialize.jl:25,76`; `SY/analyze/members/members/initialize.jl:58-63,125`).
  Only the stage-3 jump (`apply_wall_thickness!`, `SY/analyze/lateral/wall_thickness_jump.jl:640-678`)
  changes it later. [read]
- **Wall object** = plan line `(x1,y1)-(x2,y2)` + `thickness` + `story`; stored on
  the story *below* the slab it holds (`SY/building_types/members.jl:400-457`). [read]
- **Which walls meet a slab:** `supporting_wall_segments(struc, slab)`
  (`SS/slabs/codes/concrete/flat_plate/utils/helpers.jl:152-176`): a wall meets the
  slab whose elevation is within 0.1 m of the wall's story elevation *or* the next
  story above (`_wall_end_elevations_m`, `:218-231`). So a pier touches two slabs:
  the one at its base and the one at its top. Segments are deduplicated by plan key,
  so stacked piers collapse to one segment. [read]
- **Wall thickness is read live** by `_wall_thickness(struc, seg)` (`helpers.jl:200-212`)
  from `struc.walls` at the time the slab is designed → stage 1, i.e. the **user
  input thickness, before any wall jump**. [read] The design-graph contract copies
  segments, not thickness (`SY/floor_design_contracts.jl:61`). [read]
- **Gravity share (tributary):** `compute_column_tributaries!`
  (`SY/analyze/tributaries/support_tributaries.jl:772-875`) splits each cell between
  columns at its corners and walls whose top is at that cell (`_cell_top_walls`);
  wall edges take the edge polygons they cover plus end halves
  (`split_cell_walls`), result in `wall.tributary_cell_areas` /
  `wall.tributary_polygons` (`:846-851`). Geometric, independent of stiffness. [read]
  This is used for slab punching/one-way-shear demand at walls (below) and for
  tributary loads into the frame model. [read for slab checks; frame-model use inferred]
- **Two-way reclassification:** `classify_two_way_supports`
  (`SY/analyze/slabs/slabs/support_classification.jl:88-133`) — a `:two_way` panel
  with no beam edges and not walled on every side is **rewritten to `:flat_plate`**
  (`:118-122, 211-219`), so "two-way + core" is really flat plate. All-wall panel →
  keep two-way with `wall_supported=true`. Beams + interior gap → throw. Beams +
  missing building-edge beam → `missing_edge_beam=true` (10%). Walls count by
  `:walls` edge group or matching plan key (`:103-104`). [read]
- **Validation:** FEA flat plate needs `n_cols + n_walls ≥ 2` supports
  (`SY/workflow/validation.jl:151-158`). [read]

---

## 1. Flat plate / flat slab (drop panels) × walls and cores

Flat slab shares this path (drop panels add a drop around columns only; "a wall
has no drop", `SS/.../flat_plate/design/reinforcement.jl:282`). [read]

### 1a. How the wall enters the slab design

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Support type | **Line** support on the wall plan centerline segment | `helpers.jl:152-176` | read |
| FEA boundary | Shell nodes on the segment: uz fixed **and rotation about the wall axis fixed** (oblique wall: both rx, ry fixed). I.e. a rigid, rotationally fixed edge regardless of wall t, height, or cracking. Cites R13.6.3.3 | `analysis/fea/model.jl:513-552, 606-609` | read |
| FEA mesh conformity | Mesh nodes are placed along interior cell edges (`build_slab_shell_mesh` step 4) and the restraint catches nodes within 1 mm of the segment; no explicit wall constraint line (the story-shell path does pass `support_lines`, `panel_shell_beams.jl:583-606`). A wall not on a cell edge would be held only at coincident nodes | `fea/model.jl:327-340, 532` | inferred |
| EFM | Wall crossing a frame line → support at its station. **Fixed joint** (infinite stiffness) when the wall covers the strip or > ½ of it; otherwise a "column" with c1 = wall t, c2 = covered length, height = story height. Spans lying on a parallel wall are dropped | `analysis/efm/frame_lines.jl:286-342, 425-446` | read |
| EFM docstring contradiction | Docstring says "this check refuses the equivalent frame when a wall supports the slab", body only adds wall joints and never refuses | `analysis/efm/applicability.jl:59-61` vs `:127-129` | read |
| DDM | Full-edge wall = infinite-stiffness beam (R13.1); short wall = column; adds wall end spans; §13.6.1.3 successive-span check across a short wall; full-edge wall raises slab exterior negative (§13.6.3.3 col 5); parallel edge wall acts as the §13.6.3.3 edge beam via `βt_with_parallel_wall` | `analysis/ddm/applicability.jl:553-620, 706-770`; `ddm/span_analysis.jl:182-183, 436-445` | read |
| Span measurement | FEA/EFM/DDM all place the wall at its **centerline**; FEA face moment cut taken at `t/2 + δ/2` (δ = 0.20 m) from centerline; EFM face from c1 = t | `fea/frame.jl:139-169`; `frame_lines.jl:390-408` | read |
| Min thickness | Flat plate/flat slab: a wall **on the slab outline** (incl. courtyard) selects the "exterior without edge beams" Table 9.5(c) column; an interior wall does not change it; a wall is never treated as the footnote-§ edge beam | `helpers.jl:252-279`; `SS/slabs/codes/concrete/min_thickness.jl:38-47` | read |
| Wall-reaction punching | One critical section per connected wall cluster at d/2: closed 4-wall shaft loop (αs 30), re-entrant corner (αs 40), convex corner (αs 20), single wall 4-sided (αs 40) or 3-sided wall end (αs 30), non-orthogonal junction = faces only (b0 under-estimated, flagged in docstring). Vu = qu × **geometric** wall tributary area. Moment transfer from analysis `wall_transfer` via ACI 421.1R Eq 3.2/3.3; shaft walls' moments enveloped not netted. Cites §11.11.1.2, §11.11.2.1 | `design/checks/punching.jl:745-1158` | read |
| Lever on wall punching failure | **Only slab thickening** (`_jumped_depth(...; punching=true)`); no studs at walls; with `punching_thickening=false` → fail. Under `:joint_search` the candidate is rejected (no column option can fix it) | `pipeline/iteration.jl:879-918`; `pipeline/joint_search.jl:246, 281-284` | read |
| One-way shear at walls | Section at d from wall face across full wall length; Vu = qu × (trib − L·d); Vc per ACI 318-19 Table 22.5.5.1(c) with ρw at 0.0018 min. Failure → grow h (Phase A) | `design/checks/one_way_shear.jl:100-132`; `pipeline/iteration.jl:667-674`; `pipeline/thickness_jump.jl:285-287` | read |
| Wall-face flexure | FEA: hogging integrated along elements adjacent to the wall, both faces, max; split into column/middle strips with frame CS fractions. EFM/DDM: frame joint moment `M_wall_ext/int`. Short-wall extra moments: `short_wall_flexure_moments` **returns zeros** (stub; docstring says the analysis moment is used) | `fea/frame.jl:139-176`; `design/reinforcement.jl:177-267, 451-460, 470-492` | read |
| Bar anchorage into wall (§12.12.1) | Top bars at wall face must develop within `t_wall − cover` (straight ℓd §12.2.2 with ψt = 1.3, else standard hook ℓdh §12.5.2). Uses the **thinnest perpendicular wall** in the slab. Failure → slab result `wall_bar_development`, no lever (slab fails) | `design/reinforcement.jl:493-607`; `pipeline/final_design.jl:292-324` | read |
| Column bracing | Any wall that meets the slab → every column on that slab is **nonsway by inspection** (k = 1) unless `story_properties` Q is available; no wall → sway, ψ with 0.70 Ig column / 0.25 Ig slab | `utils/column_bracing.jl:22-41, 98-131` | read |
| Wall thickness timing | Read at stage 1 = user input. Slab never redesigned after jump | §0 above; `building-pipeline.md` | read |

### 1b. Staleness direction (flat plate ← wall t)

All four t-dependent slab checks become **less** demanding when the wall
thickens, so reading the pre-jump t is conservative for the slab, not unsafe:
punching b0 grows with t (`punching.jl:1046-1052, 1127-1157`), anchorage length
`t − cover` grows (`reinforcement.jl:534-548`), FEA face cut moves outward
(`fea/frame.jl:156`), EFM short-wall c1 grows. [read for the formulas;
"conservative" is inferred — the FEA restraint does not depend on t at all, and
the slab self-weight/geometry is unchanged.] One-way shear at the wall uses
length L only (no t). [read]

Size impact of the staleness: LOW–MED. A slab thickened in stage 1 to clear
wall punching or a §12.12.1 failure against a thin input wall keeps that h even
if the final wall is thicker. The anchorage check has **no lever** at all: a
too-thin input wall fails the slab outright instead of asking the wall to grow.
[inferred from the two read code paths]

### 1c. How the flat plate enters the wall's design

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Gravity axial N | Pier cut of the building FE model under unfactored D, L, roof (`solve_gravity_basic_cases`). Slab load reaches the model as **cell edge tributary loads** on frame slots; a `:walls` edge keeps a zero-section frame slot (EA=EI=0) whose fixed-end forces land on the shared wall nodes. No wall line load is added. So wall N ≈ geometric tributary, **not** the slab-FEA wall reaction | `SY/analyze/lateral/gravity_basic_cases.jl:44-91`; `SY/analyze/asap/asap/load_routing.jl:41-128`; `SY/analyze/asap/asap/model_builder.jl:140-180, 275-299, 364-397`; `wall_combinations.jl:87-116, 162-184` | read (path); "≈ tributary" inferred |
| Flat-plate FEA wall reaction | Not fed back to the wall (the story-shell raise below applies only to one-/two-way stories). The slab FEA fixes rotation at walls, which attracts more shear to walls than the tributary split; the wall never sees it | `story_shell.jl:908-937`; `size_beams_story_shell.jl:45-56` | read (no consumer); magnitude inferred |
| Out-of-plane moment Moop | `_slab_moment_into_wall`: for each slab **whose result is a `FlatPlatePanelResult`** at the pier's top or bottom joint, take `M_wall` (wall ⟂ primary span) or `M_wall_secondary` (wall ∥), or the larger for skew; **max** over slabs (top and bottom not split between the piers above/below); × `share = lw/L` | `SY/analyze/lateral/ordinary_wall_stage.jl:927-967` | read |
| What `M_wall` is | `max(|M_wall_ext|, |M_wall_int|)` (`design/results.jl:28-31, 80-82`). FEA: **largest single-wall face hogging** over all walls perpendicular to the span (integrated over that wall's length, both faces, max) (`fea/run.jl:394, 412`; `fea/frame.jl:171-176`). EFM/DDM: **largest one-frame-strip** joint moment over frame lines (`efm/frame_lines.jl:676-695, 750-751`) | as cited | read |
| Moop consumer | `e = Moop/N` per action; `e ≤ t/6` → empirical bearing §11.5.3; else magnified out-of-plane strength §6.6.4.5/§22.2 with lu = story height. Same Moop paired with every combination (incl. 0.9D) | `wall_ordinary_check.jl:93-163, 348-356, 400-406` | read |
| Empirical-bearing k | Gravity-only path hard-codes `:restrained` (k = 0.8, Table 11.5.3.2) regardless of floor type; lateral path takes `inputs.boundary` | `ordinary_wall_stage.jl:440, 506-515` | read |
| Diaphragm | `params.diaphragm_mode` (`:none` default, `:rigid`, `:shell`, `:semirigid`, `:flexible`, `:auto`). `:auto` classifies from `params.diaphragm_construction`, a **user statement not derived from the floor system**; no check that it matches the designed floor (e.g. composite deck declared `:concrete_slab`) | `SY/design/parameters.jl:228-254`; `SY/analyze/diaphragm.jl:373-399`; no other consumer of `diaphragm_construction` in SY | read |
| Semirigid membrane stiffness | Slab modulus × (1.0, 0.35) envelope factors; slab thickness from the designed slab | `parameters.jl:246-254` | read (thickness source inferred) |
| P-Δ gravity | Story K_G from factored gravity per key; flat-plate slab weight enters via cell self-weight. Flexible/semirigid → first-order | `ordinary_wall_stage.jl:112-125, 224-233, 316-318` | read |
| B.6 20% gravity share | Wall share = pier-cut dead N / total story dead N through the cut; > 20% → **throws** for B.6/B.4 rows (project limit, C12.2.1). Wall share depends on the tributary split, so floor type and wall placement decide it; nothing redistributes gravity away from walls | `SY/analyze/lateral/interactive_checks.jl:6-10, 72-155`; `ordinary_wall_stage.jl:319-327` | read |
| Row F (75/25) | Walls: Σφ Vn ≥ 0.75 V raised by ρt bumps. Frames: solved **without wall shells** at 25% (`exclude_shells=true`). **Any `:flat_plate` cell → throw** ("a flat plate has no slab-column frame in this model"). `:flat_slab` cells are **not** refused by this guard | `interactive_checks.jl:336-345, 455-501` | read |
| Slab-column frame in lateral model | The refusal message states there is no slab-column frame. Not traced: whether column-line skeleton edges of a flat-plate input carry a placeholder frame (`to_asap!` gives ungrouped edges a W10×22 placeholder, `model_builder.jl:364-397`) | — | inferred / open |
| Column bracing consistency | Slab design treats flat-plate columns as **sway** with ψ from 0.25 Ig slab when no wall meets the slab, **nonsway k = 1** when *any* wall meets it (`column_bracing.jl:22-41`). Beam-floor columns use member `Kx = Ky = 1.0` defaults (`SY/analyze/members/members/initialize.jl:25`) whether or not walls exist. The lateral model never uses an effective slab-beam width. So the gravity design's sway/nonsway assumption is not tied to the lateral model's actual stiffness | as cited | read (each piece); inconsistency inferred |

### 1d. Ordering and staleness (flat plate × walls)

- Order: slabs (stage 1, input wall t) → flat-plate member settle loop (columns,
  stale-slab redesign) → walls (jump) → member re-run → walls … (max 4) →
  foundations (`SY/workflow/pipeline_spec.jl:109-133, 166-195`). [read]
- A wall jump does **not** mark flat-plate slabs stale: staleness is column
  size only (`_slab_checked_at_installed_columns`,
  `SY/workflow/graph_builder.jl:340-343, 505-519`). Slabs see the new wall t only
  if a column also grows in the re-run. [read]
- Moop is read from whatever slab result is installed when the wall stage runs —
  stage-1 or a later stale-slab redesign; never recomputed after a jump. [read]
- Wall thickening raises wall self-weight → wall N rises (self-weight scaled in
  the proxy, `wall_thickness_jump.jl:248-258`), so e = Moop/N falls; the proxy
  does not rescale Moop. [read for N; Moop fixed inferred from `WallThicknessTrial.Moop`, `wall_thickness_jump.jl:16, 680-685`]
- No feedback from wall checks to slab h or column size. No feedback from slab
  punching at walls to wall length/thickness. [read: no such call sites found]

### 1e. Decision space at the interface (flat plate)

| Could be a variable | Today | Where | Tag |
|---|---|---|---|
| Wall vs column at a support | Geometry input (`:walls` edge group) | `initialize.jl:93-128` | read |
| Wall length / plan position | Fixed ("Length is not changed") | `ordinary_wall_stage.jl:106` | read |
| Wall thickness | Input seed, grow-only jump, grouping `:all` default | `parameters.jl:262-272` | read |
| Slab thickening vs wall-reaction studs | Only thickening (or fail) | `iteration.jl:879-918` | read |
| §12.12.1 anchorage: slab bar size vs wall t vs hook | Straight then hook; no lever if both fail | `reinforcement.jl:534-607`; `final_design.jl:292-324` | read |
| Which elements carry gravity | Geometric tributary split, fixed | `support_tributaries.jl:772-875` | read |
| Slab-column frame participation in lateral | Not modelled; row F refuses flat plate | `interactive_checks.jl:336-345` | read |
| Wall layout / carbon | `WallLayoutNLPProblem` (MinCarbon/MinDrift/weighted, SIMP over candidate lines) exists; referenced only by SS/SY tests and `scripts/runners/crit5…`, `crit7…`, `crit8…`, `crit9…`, `review_verify_crit5_fix.jl`, `redteam_wall_centroid_proxy_attack.jl`; **no SY src caller** | `SS/walls/layout_problem.jl:1-160` | read |
| Per-wall drift sensitivity | `story_drift_sensitivity` exported; no SY caller | `SS/walls/lateral/sensitivity.jl:10-15`; `SS/StructuralSizer.jl:500` | read |
| Analytic wall stiffness | `wall_lateral_stiffness(::Wall, …)` extended in SY but no sizing caller found | `SY/building_types/members.jl:595-627` | read (no caller in sizing grep) |


## 2. Two-way with beams × walls / columns

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Support classification | `classify_two_way_supports`: no beam & not all walls → rewritten to `:flat_plate` (§1 applies; @warn "A core wall is a line support on that flat plate, not a beam"). Every edge a wall → keep, `wall_supported=true`. Beams + an interior edge with neither beam nor wall → **throw**. Beams + missing building-edge beam → keep, `missing_edge_beam` (a wall fills it) | `SY/analyze/slabs/slabs/support_classification.jl:77-133, 170-237` | read |
| Wall edge counts as support | Edge in `:walls` **or** an edge whose plan key matches a wall on another level (`_wall_plan_keys`) | `support_classification.jl:91-104` | read |
| Min thickness | `wall_supported` → ACI 318-11 §9.5.3.3(c) `ln(0.8+fy/200k)/(36+9β)`, ≥3.5 in (classification, not computed αfm); otherwise αfm unknown → bound over (a)-(d) incl. Table 9.5(c) and 1.1×eq, ≥5 in | `SS/slabs/codes/concrete/min_thickness.jl:183-203`; `SS/slabs/sizing.jl:723-754` | read |
| Mixed wall/beam panel | A wall edge does not give αf; with αfm unknown the thickness uses the conservative bound, so walls do **not** thin a mixed panel | `min_thickness.jl:198-203` | read |
| Analysis stiffness at wall | Story-shell (one-/two-way-only stories): uz + longitudinal rotation held on shell nodes on wall segments; skewed walls → grounded springs | `story_shell.jl:846-1049`; `size_beams_story_shell.jl:45-56` | read |
| Wall reaction → wall | `_record_story_shell_wall_axials!` (after story-shell rounds) records factored wall-segment reactions; `_gravity_raised_to_shell` raises pier D/L axial when the shell reaction exceeds the cut | `SY/workflow/member_iteration.jl:456`; `story_shell.jl:908-937`; `SY/analyze/lateral/wall_combinations.jl:140-160` | read |
| Moop | **0** — `_slab_moment_into_wall` reads only `FlatPlatePanelResult` | `ordinary_wall_stage.jl:927-967` | read |
| Punching / one-way shear at walls, §12.12.1 | No wall-reaction punching or wall-face anchorage for two-way-with-beams (those live in the flat-plate design path) | flat_plate/design only | inferred (no call found) |
| Columns | Beam floors: columns sized in the beam/column loop; Kx = Ky = 1.0 default, independent of walls | `SY/analyze/members/members/initialize.jl:25` | read |

## 3. One-way (incl. joists) × walls

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Validity | `:one_way` cell with no `:beams`/`:walls` edge → **throw** (unless joists planned) | `SY/core/initialize.jl:90-115` | read |
| Span end condition | `_span_end_kind`: an edge in `:beams/:walls/:joists/:secondary` is a support; `:continuous` if a non-grade slab continues past it, else `:supported`. Walls and beams are indistinguishable (no wall-fixity credit; no "integral with wall" case) | `SS/slabs/sizing.jl:615-672` | read |
| Thickness | Table 7.3.1.1 condition = thickest of the cells; merged with user `support` via `thicker_support` | `sizing.jl:578-605, 682-712` | read |
| Span measured | `slab.spans.primary` (centreline geometry); wall thickness not subtracted | `sizing.jl:687-688` | read (clear-span absence inferred) |
| Tributary to walls | One-way/composite cells partition weight 1.0 to beam/wall/joist/secondary edges | `SY/analyze/tributaries/cell_tributaries.jl:96-104` | read |
| Joists | Walls are joist hosts in `joist_geometry` (a wall on another story is not) | `SY/analyze/framing/joist_geometry.jl:88, 124` | read (docstring) |
| Wall reaction / Moop | Story-shell raise applies (one-way story); Moop = 0 | as §2 | read |
| Anchorage / shear at wall | None found | — | inferred |

## 4. Waffle × walls

Waffle shares two-way pattern loading (`SY/analyze/asap/asap/pattern_cases.jl:267`)
and is "unframed" for openings (`SY/core/opening_framing.jl:13`). Waffle stories
are **not** story-shell levels (only `⊆ {:one_way,:two_way}`,
`size_beams_story_shell.jl:55`) so no shell-reaction raise; Moop = 0. Wall
handling inside waffle sizing not traced. [read for cited lines; rest inferred]

## 5. Composite deck on steel beams × walls

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Deck sizing | `span = slab.spans.primary`; no wall awareness | `SS/slabs/sizing.jl:517-539` | read |
| Bearing / web crippling | `deck_floor` has an optional bearing check; it runs only if `bearing_length` etc. are passed; **no pipeline caller passes them** → `(checked=false, ok=true)`. No ledger/embed-plate check at walls | `SS/slabs/codes/steel/deck_floor.jl:98-113`; grep `bearing_length =` (tests only) | read |
| Tributary | Partition weight to wall edges as one-way | `cell_tributaries.jl:98` | read |
| Diaphragm | `deck_floor_diaphragm` (deck span/depth classification) exists and is exported but has **no SY src caller** (tests only). `:auto` uses user `diaphragm_construction` | `SY/analyze/diaphragm.jl:373-425`; `SY/StructuralSynthesizer.jl:261` | read |
| Moop, shell raise | Moop = 0; not a story-shell type | as above | read |

## 6. Vault × walls

| Aspect | Behaviour | Where | Tag |
|---|---|---|---|
| Thrust | Factored (governing combo) thrust applied as line loads on the face edges ⟂ span (`abs(dot) < 0.1`), whatever group those edges are in | `SY/analyze/asap/asap/load_routing.jl:313-355` | read |
| On a wall edge | Wall edge frame slot is zero-section; thrust (out of wall plane) ends on wall nodes and the wall shell. Not added to Moop; wall check sees only pier cuts | `model_builder.jl:140-180`; `ordinary_wall_stage.jl:927-967` | read (path); out-of-plane-on-wall effect inferred |
| API guidance | Vault "requires RC columns and RC beams" — no explicit refusal of wall edges found | `SY/api/schema/params_schema.jl:21` | read (guidance); no throw found |

## 7. Grade walls and columns

- Grade cells carry no slab load into the frame model (skipped in routing,
  pattern cases, demands) (`load_routing.jl:10, 163`; `pattern_cases.jl:162`;
  `foundations/demands.jl:21`). Grade-wall bases fully fixed
  (`model_builder.jl:466`). [read]
- One-way `_span_end_kind`: a support next to a `:grade` cell is `:supported`
  not `:continuous` (`SS/slabs/sizing.jl:668`). [read]
- RC vs steel columns: flat plate/slab require RC columns (API guidance,
  `params_schema.jl:21`); column-floor interface is in `members.md`. [read guidance]

## 8. Unsupported / silently ignored combinations

| Combination | Outcome | Tag |
|---|---|---|
| Two-way, beams + interior edge with no beam/wall | throw (`support_classification.jl:124-131`) | read |
| Two-way, no beams, not all walls | silently → flat plate (warn) | read |
| One-way with no beam/wall edge | throw (`initialize.jl:90-115`) | read |
| Row F with any `:flat_plate` | throw; `:flat_slab` **not** caught (`interactive_checks.jl:336-345`) | read |
| B.6/B.4 with wall dead share > 20% | throw (`interactive_checks.jl:72-155`) | read |
| Non-flat-plate floor × wall Moop | silently 0 | read |
| Vault thrust onto wall edge | silently not in wall check | inferred |
| Composite deck bearing on wall | not checked | read |
| Slab group mixing support classes | throw (`support_classification.jl:186-195`) | read |

## 9. Matrix

| Floor | Wall as support | Min-h wall rule | Punching/shear at wall | §12.12.1 into wall | Slab stiffness at wall | Wall N source | Moop | Diaphragm from floor? | Lateral frame role |
|---|---|---|---|---|---|---|---|---|---|
| Flat plate | line (FEA hold uz+rot; EFM fixed/column; DDM spans) | flat-plate rules | yes (§11.11.1.2, ends/corners/loops) | yes, fail-only | fixed rotation | tributary cut | yes (max, ×lw/L) | no (user) | none; row F throws |
| Flat slab | same as flat plate | same | same | same | same | tributary | yes | no | none; row F **not** refused |
| Two-way + beams | edge support | §9.5.3.3(c) if all walls | none | none | story-shell hold/spring | max(cut, shell) | 0 | no | beams/cols frame |
| One-way / joists | end support = beam | Table 7.3.1.1 | none | none | story-shell | max(cut, shell) | 0 | no | beams/cols |
| Waffle | inferred two-way | ? | none found | none | not story-shell | tributary | 0 | no | ? |
| Composite deck | edge (weight 1) | deck tables | — | — | none | tributary | 0 | `deck_floor_diaphragm` unwired | steel frame |
| Vault | thrust edge | — | — | — | — | tributary + thrust | 0 (thrust ignored) | no | — |

## 10. Size-impact issues (ranked)

- **HIGH** — Wall t frozen for slab: wall jump doesn't restale flat-plate slabs → slab thickened/failed for wall punching/anchorage at input t (`graph_builder.jl:505-519`). [read]
- **HIGH** — Moop = max single-wall face moment × lw/L, top/bottom not split, paired with 0.9D → may drive wall t up (flat plate only). [read; magnitude inferred]
- **HIGH** — B.6 20% gate uses tributary split, no redistribution lever → throws instead of resizing. [read]
- **MED** — Flat-plate N tributary not slab-FEA reaction; two-way/one-way uses max(cut, shell) — asymmetric conservatism across floors. [read]
- **MED** — Mixed beam+wall two-way panels get no wall credit on min h. [read]
- **MED** — Sway/nonsway for flat-plate columns flips on "any wall meets slab" (`column_bracing.jl:22-41`). [read]
- **LOW** — One-way spans to centreline at walls. [inferred]
- **LOW** — Gravity-path wall bearing k fixed at 0.8 (`ordinary_wall_stage.jl:440`). [read]

## 11. Possible safety gaps (flagged, not concluded)

1. Non-flat-plate floors deliver Moop = 0 to walls (eccentric bearing of beams/one-way/vault on walls ignored). [read]
2. Vault thrust on wall edges never checked as out-of-plane wall demand. [inferred]
3. Composite deck web crippling/bearing never run in pipeline. [read]
4. `:flat_slab` escapes row-F refusal although it also has no slab-column frame. [read]
5. Flat-plate wall N from tributary, not from rotation-fixed FEA reaction (which attracts load to walls). [read path; magnitude inferred]
6. "Any wall touches slab ⇒ nonsway" by inspection for all flat-plate columns, not tied to lateral model stiffness. [read]
7. Diaphragm idealization is user-declared; no consistency check vs designed floor (e.g. bare deck declared rigid). [read]
8. No wall-reaction punching / one-way shear / anchorage checks for two-way-with-beams, one-way, waffle panels bearing on walls. [inferred: no call found]

## 12. Optimization opportunities (vertical-floor coupling)

- Restale slabs on wall-t jump (add wall t to `_slab_checked_at_installed_columns` key) → reclaim slab thickness. [inferred]
- Joint wall t + slab h: punching at wall ends vs wall length/thickness vs studs (no stud option at walls today). [inferred]
- Wire `story_drift_sensitivity` into the wall-thickness jump to grow only drift-effective walls. [inferred]
- Wire `WallLayoutNLPProblem` (MinCarbon) as an upstream wall-placement stage, trading wall carbon against column sizes/slab spans. [inferred]
- Let slab-column frame (effective width) share lateral load → relax row F, reduce walls for flat plate. [inferred]
- Use `deck_floor_diaphragm` to auto-set diaphragm for composite deck. [inferred]
- Recompute Moop after slab redesign; split top/bottom moments between piers by stiffness. [inferred]
