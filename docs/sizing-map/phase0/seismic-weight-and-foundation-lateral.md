# Phase 0 research — Seismic effective weight (W) and lateral reactions in foundation design

Status: IN PROGRESS (written incrementally). Research only — no source code edited.
Date: 2026-11-11.

Conventions:
- `SS/` = `StructuralSizer/src`, `SY/` = `StructuralSynthesizer/src`.
- Code quotes are verbatim from the corpus (`source_id`, clause, PDF page from `===== PAGE N =====` markers or corpus MCP `page_range`).
- Anything marked **ENGINEERING JUDGMENT** is not taken from a code clause.
- The corpus MCP server (`menegroth-corpus`) **was connected** in this session (the brief expected it not to be), so all quotes below came from `corpus.search_text` / `get_source_text` / `get_clause` hits on the curated text. `get_clause` returned `not-found` for `12.7.2` (no extraction exists), so I used `search_text` as the step-3 fallback.
- OCR artifacts in the corpus text (e.g. `þ` for `+`, a mangled `Σ`) are kept verbatim, with the intended reading given in [brackets].

---

# ISSUE A — Seismic effective weight W omits member and wall self-weight

## A.2 Code requirement (verbatim)

**ASCE 7-22 §12.7.2 Effective Seismic Weight** (`asce-7-22`, PDF p. 184):

> "12.7.2 Effective Seismic Weight The effective seismic weight, W, of a structure shall include the dead load above the base and other loads above the base as follows:
> 1. In areas used for storage, a minimum of 25% of the floor live load shall be included.
> 2. Where provision for partitions is made or where required by Section 4.3.2 in the floor load design, the actual partition weight or a minimum weight of 10 lb/ft2 (0.48 kN/m2) of floor area, whichever is greater.
> 3. Total operating weight of permanent equipment.
> 4. Where the flat roof snow load, Pf , exceeds 45 lb/ft2 (2.16 kN/m2), 15% of the uniform design snow load, regardless of actual roof slope.
> 5. Weight of landscaping and other materials at roof gardens and similar areas, as defined in Section 3.1.4.
> 6. Weight of fluids and bulk material expected to be present during normal use.
> EXCEPTIONS: (a) Where the total weight of Items 1, 3, 5, and 6 adds no more than 5% to the effective seismic weight at that level, the weight of these items need not be included. (b) Floor live load in public garages and open parking structures need not be included. (c) …"

**ASCE 7-22 §3.1.1 Definition (of dead load)** (`asce-7-22`, PDF p. 72). This sets what "the dead load" in §12.7.2 includes:

> "Dead loads consist of the weight of all materials of construction incorporated into the building including, but not limited to, walls, floors, roofs, ceilings, stairways, built-in partitions, finishes, cladding, and other similarly incorporated architectural and structural items, and the weight of fixed service equipment, including cranes and material handling systems."

→ **Code-derived:** W must include the self-weight of the columns, beams, walls (structural and nonstructural), and cladding above the base, not only the slab and SDL.

**ASCE 7-22 §12.8.3 Vertical Distribution of Seismic Forces** (`asce-7-22`, PDF p. 186):

> "Fx = CvxV (12.8-12)
> Cvx = Pwxhkx/(ni=1 wihki) (12.8-13)" [OCR; intended: Cvx = wx hx^k / Σ(i=1..n) wi hi^k]
> "wi, wx = Portion of the total effective seismic weight of the structure (W) located or assigned to level i or x;
> hi, hx = Height [ft (m)] from the base to level i or x; …"

**ASCE 7-22 §12.8.1** (`asce-7-22`, PDF p. 185): "V = CsW (12.8-1) … W = The effective seismic weight per Section 12.7.2."

**ASCE 7-22 C12.8.3 (commentary)** (`asce-7-22`, PDF p. 726): "In the figure, Fx is the inertial force at level x, which is simply the absolute acceleration at level x times the mass at level x."

**ASCE 7-22 C12.7.2 (commentary)** (`asce-7-22`, PDF p. 722): "When a building vibrates during an earthquake, only that portion of the seismic weight that is strongly coupled or physically tied to the structure needs to be considered as effective."

**How to assign the weight of a vertical element to levels: NOT grounded.** §12.8.3 says only "located or assigned to level i or x". I searched §12.7.2, C12.7.2, and C12.8.3 and found no rule for splitting the weight of columns and walls between levels (for example, half a story above and half below). The half-story tributary split is common practice, but **it is not stated in the corpus.** If it is adopted, it must be labelled **ENGINEERING JUDGMENT**.

**ASCE 7-22 §12.8.6.1 Minimum Base Shear and Load Combination for Computing Displacement and Drift** (`asce-7-22`, PDF p. 187):

> "The elastic analysis of the seismic force-resisting system for computing displacement and drift shall be made using the prescribed seismic design forces of Section 12.8 using a load factor of 1.0 on Eh, in the presence of expected gravity loads. Expected gravity loads shall be taken as no less than 1.0D + 0.5L, L shall be taken as 0.8L0 for live loads that exceed 100 lb/ft2 (4.79 kN/m2) and 0.4L0 for all other live loads, and L0 is the unreduced design live load (see Table 4-1)."

(The corpus text reads "1.0D + 0.5L", so 0.5L should be read together with the L definition that follows. Verify this against the rendered PDF page before coding, because the OCR may have merged lines.)

**ASCE 7-22 §12.8.7 P-Delta Effects** (`asce-7-22`, PDF p. 188):

> "θ = (Px∕hsx)/(Vx∕Δxe) (12.8-18)
> where
> Px = Total vertical design load [kip (kN)] at and above level x per Section 12.8.6.1 (where computing Px, no individual load factor need exceed 1.0);
> Vx∕Δxe = Story stiffness at level x …; and hsx = Story height below level x [in. (mm)]."
> "θmax = 0.5/βCd ≤ 0.25 (12.8-19)"

→ **Code-derived:** Px is the *total* vertical load at and above level x, with D being the full dead load (§3.1.1). Column and wall self-weight above level x must therefore be included in Px.

**ASCE 7-22 §11.2 definition of BASE** (`asce-7-22`, PDF p. 161): "BASE: The level at which the horizontal seismic ground motions are considered to be imparted to the structure."

## A.1 Current behavior (verified by reading the code, 2026-11-11)

**The premise in the brief is out of date.** The brief cites `elf_story_cases.jl:600-640`. Those lines are only the *cell* loop of `_elf_levels`. Immediately after that loop, the same function adds wall, frame, fire-coating, and drop-panel self-weight to both W and Px:

| What | Where | Behavior |
|---|---|---|
| Slab and SDL per cell | `SY/walls/seismic_mass.jl:43-47` `effective_seismic_weight` | `(cell.self_weight + cell.sdl) * cell.area`. Live load is excluded, and the §12.7.2 "other loads" (storage, snow, equipment) are not added; that is flagged in the docstring. |
| Cell loop per story | `SY/analyze/lateral/elf_story_cases.jl:610-632` | `weight += effective_seismic_weight(cell)` and `gravity += drift_expected_gravity_load(D, L0, psf)` |
| **Self-weight items** | `elf_story_cases.jl:465-515` `_elf_weight_items` | (a) wall shells per pier: `ρ t g A` through `unfactored_wall_self_weight_pressure`, **half to the `z_bot` story and half to the `z_top` story**, spread along the wall's plan segment; (b) every frame `Asap.GravityLoad` (columns and beams): `ρ A g L`, **half to each end node's story** (a beam has both ends on one floor, so it lands wholly on that floor); (c) fire coating, half to each end; (d) drop panels, wholly at the column-top floor. |
| Lumping and conservation check | `elf_story_cases.jl:524-538` `_elf_self_weight` | Throws if the lumped total ≠ the source total. |
| Elevation snapping | `elf_story_cases.jl:373-392` `_elf_elevation_key` | An item more than 1 mm from every story elevation throws, and so does an item within 1 mm of two story elevations. `_elf_deposit!` (`:395-402`) throws if the item is neither at the base nor above it, so self-weight *below* the base throws rather than being dropped. |
| Added to W and Px | `elf_story_cases.jl:652-697` | `weight = w_cell + w_sw`, `gravity = item.gravity + w_sw` (self-weight carries no live load), and the CM is combined as `(w_cell*cm_cell + Σw·x)/weight`. Base share excluded. Global check at `:680-686`. Px is accumulated top-down at `:690-696`. |
| Wall shells accounted | `elf_story_cases.jl:547-569` `_require_wall_shells_accounted` | Throws if any `:wall` shell is not in `wall_mesh`. |
| **The design rule is recorded** | `elf_story_cases.jl:454-463` | "ENGINEERING JUDGMENT … User decision 2026-10-31: half of each wall, and half of each frame member, goes to the story elevation at each end." |
| Flexible diaphragm | `SY/analyze/lateral/flexible_diaphragm.jl:228-258` `_strip_measure` | Cells (`:239`) **plus** `_elf_weight_items` pieces on that level (`:241-250`). Throws if the total ≠ `level.weight_kN` (`:254`). |
| Semirigid diaphragm | `SY/analyze/lateral/semirigid_diaphragm.jl:170-201` `_semirigid_node_weights` | Cells (`:183`) **plus** `_elf_weight_items` (`:190-194`) deposited on floor nodes. Throws if the total ≠ `level.weight_kN` (`:195-199`). |
| `story_center_of_mass` (exported) | `SY/walls/seismic_mass.jl:101-143` | **Cells only.** Inside ELF it is combined with the self-weight moments (`elf_story_cases.jl:672-673`), so the ELF CM is complete. The only other caller is `bridge_validation.jl:97` (a self-check). A future direct caller would get a cells-only CM. |
| Existing tests | `SY/test/analyze/test_elf_story_cases.jl:206-247` | Ground-story wall: Σ level weights = cells above + 0.5·w_wall. Base column GravityLoad: +0.5·w_col on the top level's `weight_kN`, `gravity_kN`, and `px_kN`. `test_semirigid_diaphragm.jl:140` and `test_diaphragm_idealization.jl:393` check the distributed totals. |

**Where member and wall self-weight live in the model:**
- Wall shells: `Asap.ShellTri3` with `id === :wall`, carrying `ρ` and `thickness`. Unfactored pressure from `unfactored_wall_self_weight_pressure` (`SY/analyze/lateral/wall_cuts.jl:631`). The factored `:wall_self_weight` AreaLoads are rewritten by `_sync_wall_self_weight!` (`SY/analyze/asap/asap/pattern_cases.jl:235-245`, called from `model_sync.jl:165`). ELF does not read those factored loads; it recomputes ρtg·A from the shells, so it always sees the current thickness.
- Frame members: one `Asap.GravityLoad(el, factor)` per element, with `factor = combo.D·g` (`member_self_weight_acceleration`, `pattern_cases.jl:183`). ELF uses `ρ A g L` from `el.section` with plain `g` (`elf_story_cases.jl:423-439`), so it is unfactored. **`to_asap!` adds no member GravityLoads** (`model_sync.jl:355-358`). They are added by sizing (`size_columns.jl:393`, `column_reconciliation.jl:218`, `member_iteration.jl`, `core/size.jl`) and restored after a wall-thickness rebuild by `_restore_sized_frame_state!` (`model_sync.jl:378-396`).
- Story elevations: `skel.stories[*].elevation` (`_elf_story_elevations`, `elf_story_cases.jl:359-365`). The base is the lowest story that has faces (`_stories_above_base`, `:312-321`).
- Stage order (`SY/workflow/pipeline_spec.jl:90-141`): slabs → beams and columns → ordinary walls (`_walls_with_member_recheck!`) → foundations. ELF therefore runs **after** the frame GravityLoads exist.

## A.3 Gap (what remains)

1. **Cladding / façade dead load is accepted but never applied anywhere.** `GravityLoads.wall_SDL` ("Cladding / curtain wall dead load (per unit area of wall)", `SS/loads/gravity.jl:29,66`, default 10 psf; API field `wall_SDL_psf`, `SY/api/deserialize/floors.jl:20`, schema guidance "Facade dead load applied to perimeter beams") **has no consumer**: a grep of `*/src/**/*.jl` for `wall_SDL` finds only the struct, its constructor, `show`, and the API deserializer. `load_map` (`gravity.jl:135-141`) does not use it. Cladding is named explicitly in the §3.1.1 dead-load definition, so it is missing from W, from Px, **and also from the gravity design and foundation loads**. This is the only confirmed omission from W.
2. **Frame self-weight is in W only if sizing has added GravityLoads.** A caller that runs `elf_story_analysis` directly after `to_asap!`, before any member sizing, gets W without columns or beams. Nothing guards against that. In the production pipeline this is not an issue because of the stage order above.
3. **The half-story split is ENGINEERING JUDGMENT, not code.** It was already decided by the user (2026-10-31) and documented. No corpus clause prescribes it (see A.2).
4. **§12.7.2 items 1, 3, 4, 5, 6** (storage live load, equipment, snow where Pf > 45 psf, roof gardens, fluids) are not modelled. This is already flagged in `seismic_mass.jl:27-41`, and the caller is expected to fold them into `sdl`. No `DesignParameters` field exists for that.
5. **§12.10 diaphragm force `Fpx` is not wired.** `diaphragm_inertial_force(Fi, wi, wpx, …)` (`SY/analyze/diaphragm_design.jl:25`) has no production caller, only `test_diaphragm_design.jl`. When it is wired, `wi` and `wpx` should come from `ElfLevel.weight_kN` so that the self-weight is included.

## A.4 Proposed change

**Code-derived:**
- Add the cladding dead load to W and Px (§12.7.2 "dead load above the base", §3.1.1 "cladding"). Cladding is dead load in D, so it would enter Px at factor 1.0 through `drift_expected_gravity_load`, exactly like the other self-weight.

**ENGINEERING JUDGMENT (needs a user decision; see A.6):**
- **Geometry:** the code has no envelope or façade surface; `apply_facade_setback!` only offsets edges. A minimal approach is `wall_SDL × story height × perimeter edge length`, applied as a `LineLoad` on perimeter (slab-edge) beams with a dedicated id (for example `:cladding`), and added to `_elf_weight_items` with the same half-story split as walls (half to the floor below and half to the floor above each façade band). Alternatively, the whole band could hang from the floor at its top (or bottom) edge, depending on the support assumption. **Which floor carries a façade band is a support-detail decision that the code does not settle.**
- Apply cladding only where there is no structural exterior wall (otherwise it is double-counted with the wall shells), or apply it to all perimeter edges and treat structural walls as uncladded. This is also a decision for the user.
- **Guard** (not a code rule): make `elf_story_analysis` fail loudly when sized frame elements exist with no `GravityLoad`, or document that it must run after sizing. A simple check: every non-`:absent`, non-wall frame element has exactly one `GravityLoad`.
- **No change is proposed to the existing half-split for walls and frames.** It is already decided, implemented, and tested.

## A.5 Consumers affected (if cladding is added to W)

- `ElfLevel.weight_kN` → `V = Cs W`, `Fx` (Eq. 12.8-13), `Vx`, accidental torsion `Mz = Fx·e`, and the CM (`elf_story_cases.jl:205-240, 670-673`).
- `ElfLevel.gravity_kN` and `px_kN` → θ (`elf_story_cases.jl:835`, `interactive_checks.jl:488`) → the 1/(1−θ) drift multiplier → the drift checks (`ordinary_wall_stage.jl:312`).
- Flexible and semirigid diaphragm load distribution. These **will throw** unless the new items are also returned by `_elf_weight_items`, because both check their total against `level.weight_kN`, so the change must go through `_elf_weight_items`.
- Unfactored dead case (`solve_gravity_basic_cases`, `gravity_basic_cases.jl:55-86`) and `_wall_dead_load_shares` (the B.6 20% check). The `test_elf_story_cases.jl:223` identity (dead-case resultant = cells above + whole wall) needs the cladding term added to both sides.
- Gravity design of the perimeter beams and columns, and the foundations (outside the seismic scope, but the same missing load).
- **Wall-stage feedback loop:** this loop already exists and is bounded. `design_ordinary_walls!` (`ordinary_wall_stage.jl:147-177`) re-runs `_analyze_lateral_walls!` → `elf_story_analysis` on every `settle!` pass after `apply_wall_thickness!`, so a thicker wall gives a heavier W and a larger ELF force on the next pass. Termination comes from thickness growing monotonically in whole inches, a pass budget of `_wall_thickness_pass_cap(grouping)+1`, and the outer `_walls_with_member_recheck!` limit of `max_rounds=4` (`pipeline_spec.jl:166-195`). Non-convergence is recorded in `stage_diagnostics[:walls]` / `[:wall_members]` and "the last analysis stands". Adding cladding (a constant) does not create a new loop. One caveat: `propose_wall_thicknesses` sizes the jump from demands computed with the *old* W, so the next pass may jump again. That is already handled by the settle loop.

## A.6 Decisions for the user

1. Should `wall_SDL` (cladding) be applied at all, and to which load paths (gravity members, foundations, W, Px)? It currently affects nothing.
2. Cladding geometry: perimeter length × story height? Excluded where a structural exterior wall exists?
3. Cladding vertical assignment: half to each adjacent floor (as for walls), or wholly to the supporting floor? (ENGINEERING JUDGMENT; not in the corpus.)
4. Should `elf_story_analysis` refuse to run when frame GravityLoads are missing (a fail-loud guard)?
5. Should a `DesignParameters` route be added for the §12.7.2 items 1, 3, 4, 5, and 6 (storage 25% LL, equipment, snow over 45 psf, roof gardens, fluids) instead of relying on the caller to fold them into `sdl`?

## A.7 Hand-calc test (known answer)

The existing tests cover the half-split for one wall and one column. The case below is a fuller known-answer case that covers the half-split for columns, beams, and walls together, plus Px.

**Geometry:** one bay, 6 m × 6 m, two stories of 4 m (levels at z = 0 (base, `:grade`), 4, 8 m). Four 0.4 × 0.4 m columns per story, four 0.3 × 0.5 m perimeter beams at each level above the base (6 m long), and one 6 m × 0.2 m wall per story on one edge. All members have ρ = 2400 kg/m³ and g = 9.80665 m/s² (`Asap.GRAVITY`). Slab cells: `self_weight` = 4.8 kPa and `sdl` = 1.0 kPa on both levels; `live_load` = 2.4 kPa on level 1 and 0.96 kPa on the roof (both under 100 psf, so L = 0.4 L0 and 0.5L = 0.2 L0).

| Item | Per story or level | Calculation |
|---|---|---|
| Slab dead per level | 208.800 kN | (4.8+1.0)·36 |
| Columns, one story (4 columns) | 60.25206 kN | 4·2400·0.16·9.80665·4/1000 |
| Beams, one level (4 beams) | 84.72945 kN | 4·2400·0.15·9.80665·6/1000 |
| Wall, one story | 112.97261 kN | 2400·0.2·9.80665·(6·4)/1000 |

Level weights (half-story split for columns and walls, beams wholly at their floor):
- w₁ (z = 4) = 208.800 + 60.25206 + 84.72945 + 112.97261 = **466.7541 kN**
- w₂ (z = 8) = 208.800 + 30.12603 + 84.72945 + 56.48630 = **380.1418 kN**
- W = **846.8959 kN**. The cells-only value would be 417.6 kN. The base share of 86.6123 kN (half of the story-1 columns and wall) is excluded.
- Conservation check: 417.6 + (2·60.25206 + 2·84.72945 + 2·112.97261) − 86.6123 = 846.8959 ✓

ELF, with Cs = 0.10 and T ≤ 0.5 s so k = 1 (§12.8.3):
- V = 84.6896 kN
- Cv₁ = 466.7541·4 / (466.7541·4 + 380.1418·8) = 1867.016/4908.150 = 0.380391 → F₁ = **32.2152 kN**
- Cv₂ = 0.619609 → F₂ = **52.4744 kN**

Px (§12.8.6.1 / §12.8.7, `drift_expected_gravity_load`):
- gravity₂ = 380.1418 + 0.2·0.96·36 = 387.0538 → Px₂ = **387.0538 kN**
- gravity₁ = 466.7541 + 0.2·2.4·36 = 484.0341 → Px₁ = **871.0879 kN**

Center of mass, level 1: the slab centroid is (3, 3), columns sit at the corners (symmetric), beams on the four edges are symmetric, and the wall is on edge x = 0 (mid-plan (0, 3)). x_cm = (466.7541·3 − 112.97261·3)/466.7541 = 3·(353.7815/466.7541) = **2.27390 m**, and y_cm = 3.0 m. This checks that the CM moves toward the wall.

Adversarial variants: (i) a member node more than 1 mm off every story elevation must throw; (ii) a frame element with no GravityLoad, once the guard decided in A.6 #4 is in place, must throw; (iii) the flexible and semirigid totals must still equal `weight_kN` once cladding is added.

---

# ISSUE B — Lateral (wind / seismic) reactions never reach foundation design

## B.2 Code requirement (verbatim)

**ASCE 7-22 §2.1 General** (`asce-7-22`, PDF p. 68): "Buildings and other structures shall be designed using the provisions of either Section 2.3 or 2.4. Where elements of a structure are designed by a particular material standard or specification, they shall be designed exclusively by either Section 2.3 or 2.4."

**ASCE 7-22 C2.1 (commentary)** (`asce-7-22`, PDF p. 558): "Foundations are also commonly designed using ASD, although strength design is used for the remainder of the structure. Using different design standards for these types of elements has not been shown to be a problem."

**ASCE 7-22 §2.3.1 Basic Combinations (strength)** (`asce-7-22`, PDF p. 68):

> "Structures, components, and foundations shall be designed so that their design strength equals or exceeds the effects of the factored loads in the following combinations. Effects of one or more loads not acting shall be considered. Seismic load effects shall be combined loads, in accordance with Section 2.3.6. The most unfavorable effects from wind loads, tornado loads, and earthquake loads shall be considered, where appropriate, but they need not be assumed to act simultaneously. …
> 1a. 1.4D
> 2a. 1.2D þ 1.6L þ (0.5Lr or 0.3S or 0.5R)
> 3a. 1.2D þ ð1.6Lr or 1.0S or 1.6R) þ (L or 0.5W)
> 4a. 1.2D þ 1.0(W or WT) þ L þ (0.5Lr or 0.3S or 0.5R)
> 5a. 0.9D þ 1.0(W or WT)
> EXCEPTIONS: 1. The load factor on L in combinations 3a and 4a is permitted to equal 0.5 for all occupancies in which Lo in Chapter 4, Table 4.3-1, is less than or equal to 100 psf (4.78 kN/m2), with the exception of garages or areas occupied as places of public assembly. …"

[`þ` = `+`, `ð` = `(`]

**ASCE 7-22 §2.3.6 Basic Combinations with Seismic Load Effects** (`asce-7-22`, PDF p. 69):

> "Where the prescribed seismic load effect, E = f ðEv; EhÞ, defined in Sections 12.4.2 or 12.14.3.1, is combined with the effects of other loads, the following seismic load combinations shall be used:
> 6. 1.2D þ Ev þ Eh þ L þ 0.15S
> 7. 0.9D − Ev þ Eh
> Where the seismic load effect with overstrength, Em = f ðEv; EmhÞ, defined in Sections 12.4.3 or 12.14.3.2, is combined with the effects of other loads, the following seismic load combination for structures shall be used:
> 6. 1.2D þ Ev þ Emh þ L þ 0.15S
> 7. 0.9D − Ev þ Emh
> EXCEPTION: 1. The load factor on L in combination 6 is permitted to equal 0.5 for all occupancies in which Lo … is less than or equal to 100 psf (4.78 kN/m2), with the exception of garages or areas occupied as places of public assembly. …"

**ASCE 7-22 §2.4.1 Basic Combinations (ASD)** (`asce-7-22`, PDF p. 69):

> "Loads listed herein shall be considered to act in the following combinations; whichever produces the most unfavorable effect on the building, foundation, or structural member shall be considered. Effects of one or more loads not acting shall be considered. … Increases in allowable stress shall not be used with the loads or load combinations given in this standard unless it can be demonstrated that such an increase is justified by structural behavior caused by rate or duration of load.
> 1a. D
> 2a. D þ L
> 3a. D þ ðLr or 0.7S or R)
> 4a. D þ 0.75L þ 0.75(Lr or 0.7S or R)
> 5a. D þ 0.6ðW or WT Þ
> 6a. D þ 0.75L þ 0.75ð0.6ðW or WT ÞÞ þ 0.75ðLr or 0:7S or RÞ
> 7a. 0.6D þ 0.6ðW or WT Þ
> EXCEPTIONS: … 2. For nonbuilding structures in which the wind or tornado load is determined from force coefficients, Cf, … it shall be permitted to replace (W or WT) with 0.9 (W or WT) in combination 7a for design of the foundation, excluding anchorage of the structure to the foundation."

(Exception 2 applies to nonbuilding structures only.)

**ASCE 7-22 §2.4.5 Basic Combinations with Seismic Load Effects (ASD)** (`asce-7-22`, PDF p. 70):

> "8. 1.0D þ 0.7Ev þ 0.7Eh
> 9. 1.0D þ 0.525Ev þ 0.525Eh þ 0.75L þ 0.1S
> 10. 0.6D − 0.7Ev þ 0.7Eh
> Where the seismic load effect with overstrength, Em = f ðEv; EmhÞ, … 8. 1.0D þ 0.7Ev þ 0.7Emh  9. 1.0D þ 0.525Ev þ 0.525Emh þ 0.75L þ 0.1S  10. 0.6D − 0.7Ev þ 0.7Emh
> Where allowable stress design methodologies are used with the seismic load effect defined in Section 12.4.3 or 12.14.3.2 and applied in load combinations 8, 9, or 10, allowable stresses are permitted to be determined using an allowable stress increase factor of 1.2. …"

**ASCE 7-22 §12.4.2 Seismic Load Effect** (`asce-7-22`, PDF p. 182):

> "E = Eh þ Ev (12.4-1)
> E = Eh − Ev (12.4-2)
> where Eh is the effect of horizontal seismic forces as defined in Section 12.4.2.1, and Ev is the vertical seismic effect applied in the vertical downward direction as determined in Section 12.4.2.2. Ev shall be subject to reversal to the upward direction in accordance with the applicable load combinations. Eh, and Ev shall be used in load combinations 6 and 7 in Section 2.3.6 and in load combinations 8, 9, and 10 in Section 2.4.5."

**ASCE 7-22 §12.4.2.1 / §12.4.2.2** (`asce-7-22`, PDF p. 183):

> "Eh = ρQE (12.4-3)
> where QE is the effects of horizontal seismic forces from V or Fp (where required by Section 12.5.3 or 12.5.4, such effects shall result from application of horizontal forces simultaneously in two directions at right angles to each other), and ρ is the redundancy factor, as defined in Section 12.3.4.
> 12.4.2.2 Vertical Seismic Load Effect The vertical seismic load effect, Ev, shall be determined in accordance with Equation (12.4-4a) as follows:
> Ev = 0.2SDSD (12.4-4a)
> where SDS is the design spectral response acceleration parameter at short periods obtained from Section 11.4.5, and D is the effect of dead load.
> EXCEPTIONS: … 2. The vertical seismic load effect, Ev, is permitted to be taken as zero for either of the following conditions:
> (a) In Equations (12.4-1), (12.4-2), (12.4-5), and (12.4-6) for structures assigned to Seismic Design Category B, and
> (b) In Equation (12.4-2) where determining demands on the soil–structure interface of foundations."

Overstrength (§12.4.3, Em = Emh ± Ev, PDF p. 183) applies only "Where required" by other provisions (e.g., collectors, discontinuous elements). No §12.13 clause read here requires Ω0 for ordinary spread/strip footings, so this document does **not** claim it applies to them. If Ω0 is needed for a specific element (e.g., a footing under a discontinuous wall), that is a **user decision to be grounded separately**.

**ASCE 7-22 §12.1.5 Foundation Design** (`asce-7-22`, PDF p. 172): "The foundation shall be designed to resist the forces developed and to accommodate the movements imparted to the structure and foundation by the design ground motions. … The design and construction of foundations shall comply with Section 12.13."

**ASCE 7-22 §12.13.4 Reduction of Foundation Overturning** (`asce-7-22`, PDF p. 195):

> "Overturning effects at the soil–foundation interface are permitted to be reduced by 25% for foundations of structures that satisfy both of the following conditions:
> (a) The structure is designed in accordance with the equivalent lateral force analysis as set forth in Section 12.8, and
> (b) The structure is not an inverted pendulum or cantilevered column type structure.
> Overturning effects at the soil–foundation interface are permitted to be reduced by 10% for foundations of structures designed in accordance with the modal analysis requirements of Section 12.9."

**ASCE 7-22 §12.13.6 Allowable Stress Design for Foundation Geotechnical Capacity** (`asce-7-22`, PDF p. 196):

> "Where basic combinations for allowable stress design listed in Section 2.4 are used for design, combinations that include earthquake loads, E, are permitted to include reduction of foundation overturning effects defined in Section 12.13.4. Allowable foundation load capacities, Qas, shall be determined using allowable stresses in geotechnical materials that have been determined by geotechnical investigations required by the Authority Having Jurisdiction."

**ASCE 7-22 C12.13.6 (commentary)** (`asce-7-22`, PDF p. 760): "… allowable soil stresses for dead plus live loads often are increased arbitrarily by one-third for load combinations that include wind or seismic forces. That approach may be both more conservative and less consistent …" (Commentary only. It is not a requirement. §2.4.1, quoted above, prohibits allowable-stress increases unless they are justified.)

**ACI 318-11 §15.2.2** (`aci-318-11`, PDF p. 271):

> "Base area of footing or number and arrangement of piles shall be determined from unfactored forces and moments transmitted by footing to soil or piles and permissible soil pressure or permissible pile capacity determined through principles of soil mechanics."

**ACI 318-19 R13.2.6.1** (`aci-318-19`, PDF p. 196):

> "The size of the base area of a footing on soil or the number and arrangement of deep foundation members are established by using allowable geotechnical strength and service-level load combinations or by using nominal geotechnical strength with resistance factor and factored load combinations."

**ACI 318-19 R13.2.6.3** (`aci-318-19`, PDF p. 196; the corpus text has OCR character doubling on this page. The quote below removes the doubled characters, so check it against the PDF before you cite it in code):

> "To design a footing or pile cap for strength, the induced reactions due to factored loads applied to the foundation should be determined. … For the case of footings or mats with eccentric loading, applied factored loads may be used to determine soil pressures."

**ACI 336.2R §1.4** (`aci-336-combined-footings-mats`, PDF p. 4; two-column text de-interleaved):

> "1.4.1 Evaluation of soil pressure—Select the combinations of unfactored (service) loads which will produce the greatest contact pressure on a base area of given shape and size. … Loads should be of Types D, L, F, W, and E as described in Section 1.3.2, and should include the vertical effects of moments caused by horizontal components of these forces and by eccentrically … applied vertical loads. … b. Obtain earthquake forces using the applicable building code, and rational analysis."
>
> "1.4.2 Foundation strength design— … it is best to design footings or mat foundations based on the Strength Design Method of ACI 318. … After the evaluation of soil pressures and settlement, apply the load factors in accordance with Section 9.2 of ACI 318."
>
> "1.4.3 Overturning—Select from the several applicable loading combinations the largest overturning moment Mo as the sum of all simultaneously applicable unfactored (service) load moments (MF, Mw, and ME) and the least unfactored resistance moment MR resulting from D and F to determine the stability ratio SRo against overturning in accordance with the provisions of Chapter 4."

## B.1 Current behavior (verified by reading the code, 2026-11-11)

1. **Entry point.** `SY/src/workflow/capture_results.jl:18-45` `_size_foundations!` calls `initialize_supports!(struc)`, then `size_foundations!` with the soil and options. It does not pass any load cases or combinations.
2. **Factored demand = reactions from the last mutating solve.** `SY/src/analyze/foundations/supports.jl:11-70` `initialize_supports!` copies `model.nodes[v].reaction` into `Support.forces` / `Support.moments`. The last mutating solve is the gravity solve: `_solve_struc_model!` inside `_solve_with_patterns!` (`SY/src/analyze/asap/asap/pattern_cases.jl:97-108`), which runs the **full-loading** gravity case. The pattern cases (`:111`) and every lateral case are solved with non-mutating `Asap.solve(model, cases, …)`, which returns displacement vectors only. Pattern reactions never reach the footings. That is a separate, gravity-only gap.
3. **Lateral cases.** The wind and ELF story cases in `ordinary_wall_stage.jl` (~795-847) and `elf_story_cases.jl:242` are solved with non-mutating `Asap.solve`. No code path computes `S[fixed,:]*u - F` for these cases. **No wind or seismic base shear, overturning moment, or uplift reaches any `FoundationDemand`.**
4. **Service demand Ps.** `SY/src/analyze/foundations/demands.jl:57-68` `_service_reactions` runs a single unfactored **D + L** case (the docstring at `:79` cites ASCE 7-16 §2.4.1 combo 2). Only `R_s[gid[3]]`, the vertical force, is used (`:133`). There is no service moment and no service shear.
5. **Demand object.** `demands.jl:81-87` / `:117-140` build one `FoundationDemand(Pu, Mux, Muy, Vux, Vuy, Ps)` per support (`SS/src/foundations/types.jl:481-493`). The struct holds exactly **one** factored set and **one** service axial force. It cannot represent a combination envelope.
6. **Grade walls.** `SY/src/analyze/foundations/wall_groups.jl:418-424` reads `nd.reaction[3]` (the full-load gravity case) for `pu`, and `R_s[...]` (D + L) for `ps`, at each wall base node. In-plane overturning from lateral load would show up as a tension/compression gradient along the wall base nodes, but those nodes only ever carry gravity reactions. **No lateral reaction reaches wall footings either.**
7. **Spread footing bearing.** `SS/src/foundations/codes/aci/spread_footing.jl:668-704` sets `A_req = Ps/qa`. It then grows the square footing until the resultant lies in the kern and `q_max_s = (Ps/A)·(qe.q_max/qe.qu) ≤ qa`. The eccentricity comes from **factored** `Mux/Pu`, on the stated assumption that "load factors cancel when Ms/Ps = Mux/Pu" (`:684-685`). That assumption only holds when every load effect is scaled by the same factor. It fails once wind or seismic moments, which have their own factors, are combined with dead load.
8. **Shear / sliding.** `Vux` and `Vuy` are stored but never read anywhere in `SS/src/foundations/**`; a grep for `.Vux`, `.Vuy`, and `sliding` returns no matches. Sliding is not checked.
9. **Uplift.** `uplift = Fz < 0` (`demands.jl:83`) is evaluated only for the gravity full-loading case. Uplift under combinations such as 0.9D − Ev + Eh or 0.6D + 0.6W is never checked.

## B.3 Gap

- **G1 (safety-critical).** Footing plan size and soil bearing are checked only for D + L. ASCE 7-22 §2.4.1 requires "whichever produces the most unfavorable effect on the … foundation", and ACI 336.2R §1.4.1 requires the service combination "which will produce the greatest contact pressure … includ[ing] the vertical effects of moments caused by horizontal components". Combinations 5a, 6a, 7a, 8, 9, and 10 are missing.
- **G2 (safety-critical).** Footing structural strength (flexure, one-way shear, punching) uses only the gravity full-loading reaction. §2.3.1 combinations 4a and 5a and §2.3.6 combinations 6 and 7 are missing.
- **G3.** Uplift and net tension under 0.9D or 0.6D plus lateral load are not detected, so there is no check for tension piles, anchorage, or overturning stability (ACI 336.2R §1.4.3).
- **G4.** Base shear (sliding) is not checked.
- **G5.** Pattern-live reactions are not enveloped for footings. This is gravity only and lower severity, but it is the same root cause: reactions are taken from a single mutating solve.
- **G6.** `FoundationDemand` holds a single (P, M) set. A bearing check over several combinations needs per-combination (P, Mx, My, Vx, Vy) sets, because the governing combination differs between maximum q, minimum q (kern/uplift), and strength design.

## B.4 Proposed change

**Code-derived requirements:**
1. Compute support reactions for each primitive load case: D, L, (Lr/S), each wind direction, and each ELF direction including accidental-torsion variants. Reactions per case are R = S[fixed,:]·u − F[fixed], the same formula as `_service_reactions`, applied to the existing `Asap.solve` outputs.
2. Combine primitive reactions linearly with the ASCE 7-22 factors:
   - Bearing and geotechnical checks: ASD §2.4.1 combinations 1a–7a and §2.4.5 combinations 8–10, or strength-level geotechnical design per §12.13.5 if the user chooses it.
   - Concrete strength: §2.3.1 combinations 1a–5a and §2.3.6 combinations 6–7.
   - Use Eh = ρ·QE (Eq. 12.4-3) and Ev = 0.2·SDS·D (Eq. 12.4-4a).
3. Bearing check for each ASD combination: use that combination's own P, Mx, and My (no Mux/Pu proxy) to get q_max and the kern/contact state, and require q_max ≤ qa.
4. Strength design for each LRFD combination: use factored soil pressure from that combination's eccentric resultant (ACI 318-19 R13.2.6.3, quoted above).
5. Uplift check on every ASD and LRFD combination. Report net tension.

**Code-permitted options (each one is a user choice, not automatic):**
- §12.13.4: 25% reduction of overturning at the soil–foundation interface. It applies only to ELF, non-inverted-pendulum structures. §12.13.6 allows it inside ASD combinations with E. The reduction does **not** apply to footing concrete strength design, because the clause says "at the soil–foundation interface".
- §12.4.2.2 Exception 2(b): Ev = 0 in Eq. 12.4-2 (the "−Ev" combinations) for soil–structure-interface demands only.
- §12.4.2.2 Exception 2(a): Ev = 0 for Seismic Design Category B.
- §2.3.1 / §2.3.6 Exception 1: factor of 0.5 on L when Lo ≤ 100 psf.

**ENGINEERING JUDGMENT (not prescribed by the quoted text):**
- How to treat a resultant outside the kern under transient lateral combinations. The current code rejects any plan with q_min < 0. Common practice accepts partial contact for wind/seismic with a triangular pressure block, q_max = 2P / (3B(L/2 − e)). I have not grounded that formula in the corpus in this session, so it needs a citation before implementation.
- Whether to keep the current `Ms/Ps = Mux/Pu` proxy for the gravity-only combination. It is valid only when all loads in the combination share one factor.
- How many lateral directions to combine. Orthogonal-combination rules (§12.5) are not quoted here.

**Minimal implementation shape (for a later phase, not done here):** add a per-support vector of (combination label, P, Mx, My, Vx, Vy, kind ∈ {ASD, LRFD}) to the demand, populated from per-case reactions. Then size the footing plan from the ASD envelope and the thickness and steel from the LRFD envelope. The same applies to the grade-wall node path in `wall_groups.jl:418-424`.

## B.5 Consumers affected

- `SY/src/analyze/foundations/supports.jl` (`initialize_supports!`), `demands.jl` (`support_demands`, `_service_reactions`, `_foundation_demand_from_signed`, `_all_uplift`, `_mixed_sign_Pu`), `wall_groups.jl` (`collect_grade_wall_groups`).
- `SS/src/foundations/types.jl` `FoundationDemand`, and every footing designer that reads it: spread (`spread_footing.jl`), strip/combined, mat, and grade-wall strip footings.
- Foundation grouping and strategy selection (`:auto`, `:auto_strip_spread`, `:mat`). These compare plan areas, so they will change once lateral combinations govern.
- Results capture and the API output: foundation sizes, governing combination labels, and new failure modes (uplift, sliding).
- Lateral reactions depend on W (Issue A), so any change to W also changes foundation demands. There is no feedback loop: foundations do not feed back into W, because §12.7.2 counts only dead load *above the base*.

## B.6 Decisions for the user

1. **Geotechnical basis:** ASD (§2.4 with qa), strength-level geotechnical design (§12.13.5 with φ), or both?
2. **Combination set:** which §2.4 and §2.3 combinations to run. All of them, or only those with non-zero load types? Include Lr/S/R?
3. **§12.13.4 overturning reduction:** apply it (25% for ELF)? It is a permission, not a requirement.
4. **Ev = 0 at the soil interface** (§12.4.2.2 Exc. 2(b)): use it?
5. **Live-load factor 0.5** (Exception 1): apply automatically when Lo ≤ 100 psf?
6. **Uplift/tension:** error out, add footing weight or a deeper footing, require anchors or tension piles, or flag only? Which stability ratio SRo to use (ACI 336.2R Ch. 4, not quoted here)?
7. **Partial contact (outside the kern) under transient combinations:** allow it, and which source to cite?
8. **Allowable soil pressure increase** for W/E combinations: §2.4.1 forbids it unless justified, and C12.13.6 calls the one-third increase "arbitrary". Default: no increase. Confirm.
9. **Sliding:** add a check, and with what friction coefficient and safety factor (geotechnical input)?
10. **Footing self-weight and soil overburden** in P: they should be part of D for bearing and uplift. Confirm the source of the soil unit weight.
11. **Lateral directions:** ±X and ±Y separately, or with orthogonal 100%/30% combination (§12.5, not quoted)?
12. **Pattern live load** for footings: envelope the pattern cases, or keep full loading?

## B.7 Hand-calc test proposal (known answer)

**Setup.** A single cantilever shear wall on a rigid strip footing, analyzed in-plane.
- Footing L = 7.0 m along the wall, B = 1.5 m, so A = 10.5 m², L/6 = 1.1667 m, and S = B·L²/6 = 12.25 m³.
- Footing self-weight is excluded so the test isolates the superstructure reactions. Add it in a second test.
- Service reactions at the wall base: D = 600 kN, L = 200 kN (Lo ≤ 100 psf).
- Strength-level ELF on the wall: F1 = 30 kN at h = 4 m and F2 = 55 kN at h = 8 m. So QE base shear V = 85 kN and QE overturning M = 30·4 + 55·8 = **560 kN·m**.
- ρ = 1.0, SDS = 0.5, so Ev = 0.2·0.5·D = **60 kN**. Assume SDC D, so Exception 2(a) does not apply.
- Linear pressure: q = P/A ± M/S, valid while e = M/P ≤ L/6.

**ASD bearing** (allowable q, kPa):

| Combo | P (kN) | M (kN·m) | e (m) | q_max | q_min |
|---|---|---|---|---|---|
| 2a D+L | 800 | 0 | 0 | 76.19 | 76.19 |
| 8 D+0.7Ev+0.7Eh | 642 | 392 | 0.611 | 93.14 | 29.14 |
| 9 D+0.525Ev+0.525Eh+0.75L | 781.5 | 294 | 0.376 | **98.43** | 50.43 |
| 9 with §12.13.4 (M×0.75) | 781.5 | 220.5 | 0.282 | 92.43 | 56.43 |
| 10 0.6D−0.7Ev+0.7Eh | 318 | 392 | 1.233 > L/6 | partial contact | <0 |
| 10 with Ev=0 (Exc. 2(b)) | 360 | 392 | 1.089 | 66.29 | 2.29 |
| 10 with Ev=0 and §12.13.4 | 360 | 294 | 0.817 | 58.29 | 10.29 |

Expected behavior with qa = 80 kPa:
- The **current code passes** (D + L gives 76.19 ≤ 80).
- The **corrected code must fail or enlarge** the footing, because combination 9 gives 98.43 > 80. Even with the §12.13.4 reduction it gives 92.43 > 80.
- ASD combination 10 without Exc. 2(b) is outside the kern (e = 1.233 m > 1.167 m). The test must confirm that the code takes the chosen decision path: reject, or use partial contact. As a reference value for judgment only (formula not grounded in the corpus), the triangular block gives q_max = 2·318/(3·1.5·(3.5 − 1.233)) = 62.34 kPa over a contact length of 6.80 m.

**LRFD footing strength** (factored soil pressure, kPa):

| Combo | P (kN) | M (kN·m) | q_max | q_min |
|---|---|---|---|---|
| 2a 1.2D+1.6L | 1040 | 0 | 99.05 | 99.05 |
| 6 1.2D+Ev+Eh+1.0L | 980 | 560 | **139.05** | 47.62 |
| 7 0.9D−Ev+Eh | 480 | 560 | 91.43 | 0.00 (e = L/6 exactly) |

Expected behavior:
- Combination 6 governs footing flexure and shear, at 1.40× the current gravity-only peak pressure.
- Combination 7 sits exactly on the kern boundary. It is a deliberate edge case for floating-point tolerance in `_eccentric_in_kern`.
- The §12.13.4 reduction must **not** change the LRFD values, because it applies to the soil interface only.

**Wind analogue (same footing):**
- Take W overturning = 400 kN·m.
- ASD 7a, 0.6D + 0.6W: P = 360, M = 240, so q = 34.29 ± 19.59 = 53.88 / 14.69 kPa.
- ASD 5a, D + 0.6W: P = 600, M = 240, so q = 57.14 ± 19.59 = 76.73 / 37.55 kPa.
- Use this to check that each wind direction's reactions are extracted with the correct sign: reversing W must swap q_max to the other end of the footing.

**Integration test:** a two-bay frame plus wall building with nonzero ELF. Assert that `FoundationDemand` holds per-combination entries, and that the governing ASD combination for the wall footing is a seismic one, not 2a.


