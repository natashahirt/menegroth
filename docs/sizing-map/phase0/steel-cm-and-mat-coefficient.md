# Phase 0 research — Steel Cm default (Issue C) and mat single-span coefficient (Issue D)

Status: COMPLETE (research only; no source code changed).
Corpus access: `user-menegroth-corpus` MCP server was connected in this session (confirmed via GetDynamicTools); MCP tools used first, direct reads of `corpus/text/**` as fallback where noted.

---

## Issue C — Steel Cm default

### C.1 Current behavior (file:line)

**Default in the demand type.** `StructuralSizer/src/members/types/demands.jl:86-100`:
`M1x = isnothing(M1x) ? zero(Mux) : M1x`, `M2x = isnothing(M2x) ? Mux : M2x` (same for y);
`transverse_load=false` (line 93). The docstrings at lines 43-44 and 77-78 call this the
"conservative single-curvature stand-in: `Cm = 0.6`". That label is **wrong twice**:
`M1 = 0` is not single curvature (single curvature is `M1 = −M2`, giving Cm = 1.0), and
Cm = 0.6 is not conservative relative to unknown curvature. Note the sibling
`RCColumnDemand` docstring (same file, lines 152-154) already states the correct reading:
"This is NOT conservative: single curvature (`M1 = −M2`) gives Cm = 1.0".

**Cm.** `StructuralSizer/src/members/codes/aisc/generic/moment_amplification.jl:34-44`
`compute_Cm`: `transverse_loading → 1.0`; `|M2| < 1e-10 → 1.0`; else `0.6 − 0.4·(M1/M2)`
(no clamp — matches Eq. A-8-4). Docstring cites "corpus aisc-360-16, p. 244": that is the
printed page 16.1-250 region; the **PDF page is 306** (minor citation fix).

**B1.** Same file, lines 80-95 `compute_B1`: `Pr ≤ 0 → 1.0`; `α·Pr/Pe1 ≥ 1 → Inf`;
else `max(Cm/(1 − α·Pr/Pe1), 1.0)` — matches Eq. A-8-3.

**Where B1 is applied (task 2).**
- `StructuralSizer/src/members/codes/aisc/checker/steel_feasibility.jl:79-114` — inside
  `if Pu_c > 0.0`: `Pe1 = π²·E·I/(K·L)²` per axis, `Cm` from `demand.M1*/M2*` and
  `demand.transverse_load`, `B1_x`/`B1_y` with α = 1.0 (LRFD); amplified `Mux`, `Muy`,
  `Mux_neg` feed the §H1.1 compression interaction (lines 132-146). Tension interaction
  (§H1.2) uses first-order moments. **B1 only matters when `Pu_c > 0`** — otherwise all
  moments are first-order (consistent with App. 8 "B1 shall be taken as 1.0 for members not
  subject to compression").
- Same logic duplicated in `checker/composite_feasibility.jl:108-111` and `:375-378`, and in
  `checker/explanations.jl:100-103` and `:328-331` (diagnostic output).
- B1 multiplies the **total** first-order envelope `Mux` (not `Mnt` only); B2 is not
  implemented (`steel_feasibility.jl:52-59` warns when `braced=false`). That is a separate
  issue, not addressed here.
- Steel **NLP** problems (`members/optimize/problems/w_column.jl:314-327`,
  `hss_column.jl`) use `p.Mux_kipft` directly in H1 — **no B1 at all**, and the NLP
  column result is not re-checked by `AISCChecker` (`api/columns.jl:622-656`). Out of the
  strict Cm scope but a related P-δ gap on the steel-column NLP path.

### C.2 Code requirement (verbatim + citation)

Source: `aisc-360-16` (AISC 360-16), Appendix 8, PDF page 305 (printed 16.1-249):

> "8.2. CALCULATION PROCEDURE
> The required second-order flexural strength, Mr, and axial strength, Pr, of all members shall be determined as:
> Mr = B1 Mnt + B2 Mlt (A-8-1)
> Pr = Pnt + B2 Plt (A-8-2)
> where
> B1 = multiplier to account for P-δ effects, determined for each member subject to compression and flexure, and each direction of bending of the member in accordance with Section 8.2.1. B1 shall be taken as 1.0 for members not subject to compression."

`aisc-360-16`, App. 8 §8.2.1, PDF page 306 (printed 16.1-250):

> "1. Multiplier B1 for P-δ Effects
> The B1 multiplier for each member subject to compression and each direction of bending of the member is calculated as:
> B1 = Cm / (1 − αPr/Pe1) ≥ 1 (A-8-3)
> where
> α = 1.0 (LRFD); α = 1.6 (ASD)
> Cm = equivalent uniform moment factor, assuming no relative translation of the member ends, determined as follows:
> (a) For beam-columns not subject to transverse loading between supports in the plane of bending
> Cm = 0.6 − 0.4(M1/M2) (A-8-4)
> where M1 and M2, calculated from a first-order analysis, are the smaller and larger moments, respectively, at the ends of that portion of the member unbraced in the plane of bending under consideration. M1/M2 is positive when the member is bent in reverse curvature and negative when bent in single curvature.
> (b) For beam-columns subject to transverse loading between supports, the value of Cm shall be determined either by analysis or conservatively taken as 1.0 for all cases.
> Pe1 = elastic critical buckling strength of the member in the plane of bending, calculated based on the assumption of no lateral translation at the member ends, kips (N)
> = π²EI* / (Lc1)² (A-8-5)"

(Subscripts were flattened by the PDF text layer; reassembled here from the same lines.)

The user note on the same page: "B1 values other than unity apply only to moments in beam-columns".

Commentary, `aisc-360-16` Comm. App. 8, PDF page 638-639 (printed 16.1-582/583):

> "For beam-columns with transverse loadings, the second-order moment can be approximated for simply supported members with Cm = 1 + ψαPr/Pe1 (C-A-8-2) ... For restrained ends, some limiting cases are given in Table C-A-8.1 together with two cases of simply supported beam-columns (Iwankiw, 1984). These values of Cm are always used with the maximum moment in the member."
>
> "In lieu of using the equations given in Table C-A-8.1, the use of Cm = 1.0 is conservative for all transversely loaded members. It can be shown that the use of Cm = 0.85 for members with restrained ends, as specified in AISC Specifications prior to 2005, can sometimes result in a significant underestimation of the internal moments. Therefore, the use of Cm = 1.0 is recommended as a simple conservative approximation for all cases involving transversely loaded members."

Table C-A-8.1 (PDF p. 640) lists ψ ∈ {0, −0.4, −0.4, −0.2, −0.3, −0.2} with Cm = 1.0 or
1 − |ψ|·αPr/Pe1; the **case sketches are images and are not in the text layer**, so which
ψ belongs to which load/support case is UNGROUNDED in the corpus — do not implement the
table without the PDF figure.

### C.3 Gap

Classification of every `MemberDemand` construction site (task 3). "Default" = `M1`/`M2`
omitted ⇒ `M1 = 0`, `M2 = Mux` ⇒ Cm = 0.6 (when `Mux > 0`).

| Site | Members | M1/M2 set? | transverse_load | Pu_c > 0 possible? | Effective Cm |
|---|---|---|---|---|---|
| SY `analyze/members/members/demands.jl:921-929` (`extract_end_moments`, column groups) | columns | yes, signed FEA | `false` | yes | 0.6−0.4·M1/M2 (correct form) |
| SY `demands.jl:931-938` (beams, struts) | beams, girders, struts/braces | **no** | **false (default)** | yes (from FEA `min(f.P) < 0`, lines 752-753) | **0.6** |
| SS `members/optimize/api/columns.jl:241-248` (array `size_columns`, steel) | **all production steel beams AND steel columns** | **no** | **false** | yes | **0.6** |
| SS `api/conversions.jl:55-58` `to_steel_demands` | RC→steel conversion | yes (forwarded) | forwarded | yes | as given |
| SS `api/steel_columns_nlp.jl:73`, `:218` | NLP HSS/W columns | no | false | yes | n/a — NLP H1 has no B1 |
| SS `api/steel_beams_nlp.jl:266`, `:332` | NLP beam verify | no | false | no (`Pu_c = 0`) | B1 = 1 (irrelevant) |
| SS `api/beams.jl:378`, `:498` | PixelFrame beams/columns | no | false | yes | PixelFrameChecker does not read Cm/M1/M2 (not AISC) |
| SY `api/agent_tools/diagnosis.jl:63` | steel beam diagnosis | no | false | `Pu_c = 0` hard-coded | B1 = 1 (diagnosis ignores axial — reporting gap) |
| SY `api/agent_tools/diagnosis.jl:148` | steel column diagnosis | **no** | false | yes | **0.6** |
| SY `api/experiments/columns.jl:238` | column swap experiment | **no** | false | yes | **0.6** |
| SY `api/experiments/beams.jl:74` | beam swap experiment | no | false | no | B1 = 1 |
| SS docstring examples (`problems/w_column.jl:41`, `hss_column.jl:36`, `optimize/solvers/discrete/model.jl:107`) | examples | — | — | — | — |

Key routing facts (verified by reading the callers):
1. **Steel beams** (`SY size_beams.jl:666-762`) pass `Pu = d.Pu_c` to
   `StructuralSizer.size_beams` → `size_columns(Pu, Mu, ...)` (`SS api/beams.jl:266`) →
   rebuild at `columns.jl:241` with no `M1/M2`, no `transverse_load`. Every steel beam with
   FEA compression therefore gets **Cm = 0.6**, although it carries floor load between
   supports — App. 8 §8.2.1(b) applies (Cm by analysis or 1.0), and (a) is not applicable
   at all.
2. **Steel columns** (`SY size_columns.jl:146-162`) call `member_group_demands`, which does
   compute signed `M1x/M2x/M1y/M2y` (lines 792-801), but then extract only
   `Pu, Pu_t, Mux, Muy` and call the array `size_columns` — **the FEA end moments are
   discarded** and the rebuilt demand at `columns.jl:241` uses `M1 = 0` ⇒ Cm = 0.6. A
   single-curvature steel column (true Cm = 1.0) is checked at Cm = 0.6. (Only the
   precompile-only `size_steel_members!(member_edge_group=:columns)` path keeps the
   end moments; the precompile block at `StructuralSynthesizer.jl:434` uses `:beams`.)
3. **Struts/braces** reach the default only via `size_steel_members!(:struts)`
   (`demands.jl:973-1030`). `_add_gravity_loads!` (line 989) adds self-weight to the group's
   edges, so an inclined/horizontal strut gets a small transverse moment; with
   `Pu_c > 0` it is checked at Cm = 0.6 instead of (b). Effect is bounded by the small
   self-weight moment. Pinned braces with `Mux ≈ 0` are unaffected (B1 multiplies 0, and the
   `|M2| < 1e-10` guard returns 1.0).
4. Secondary (column groups via the end-moment path): `M1/M2` come from the member with the
   largest `|M2|` (lines 796-801), while `Pu_c` and `Mux` are the group maxima over all
   members/cases. A different member in the same group can be in single curvature with a
   slightly smaller `|M2|`; the group Cm can then be lower than that member's. ENGINEERING
   JUDGMENT flag; not a code clause.

### C.4 What is unconservative, and by how much (task 4)

With r = α·Pr/Pe1 (LRFD α = 1.0):

- Code value for a transversely loaded member (b, conservative choice) or a single-curvature
  member (a, M1/M2 = −1): Cm = 1.0 ⇒ B1 = 1/(1 − r).
- Current default: Cm = 0.6 ⇒ B1 = max(0.6/(1 − r), 1).

Ratio B1,code / B1,current:
- r < 0.4: B1,current = 1.0, so the moment term is under-amplified by **1/(1 − r)**:
  r = 0.10 → 1.11; r = 0.20 → 1.25; r = 0.30 → 1.43.
- r ≥ 0.4: ratio = 1/0.6 = **1.667** (constant).

Only the moment terms of H1-1a/H1-1b are affected; the H1 utilization error is
`(8/9)·(B1,code − B1,current)·Mux/φMnx` (H1-1a) — largest for slender columns with high
axial load and significant moment. For floor beams Pe1 (strong axis, `Kx·L`) is usually
large relative to `Pu_c`, so r is typically small and the error is a few percent; for
gravity columns in single curvature it can reach tens of percent.

### C.5 Proposed change (task 4)

Code-derived (cite `aisc-360-16` App. 8 §8.2.1, PDF p. 306):
1. **Steel beams / girders / joists / struts carrying span load**: set
   `transverse_load = true` at the demand construction for non-column groups
   (`SY demands.jl:931-938`) **and** thread `transverse_load` through the array
   `size_columns`/`size_beams` (currently dropped at `SS columns.jl:241`). §8.2.1(b):
   "conservatively taken as 1.0 for all cases".
2. **Steel columns**: forward `M1x/M2x/M1y/M2y` (and `transverse_load`) from
   `member_group_demands` into the steel sizing call (`SY size_columns.jl:157-162`) — e.g.
   via a demand-vector `size_columns(demands, geometries, opts::SteelColumnOptions)`
   overload mirroring the RC one — so Eq. A-8-4 uses the FEA curvature already computed.

ENGINEERING JUDGMENT (not code):
3. Change the `MemberDemand` default for unknown end moments from `M1 = 0` to
   `M1 = −M2` (single curvature ⇒ Cm = 1.0), or make `M1/M2` required when `Pu_c > 0` and
   `Mux > 0`. The spec gives no "unknown curvature" rule; Cm = 1.0 is the upper bound of
   Eq. A-8-4 for |M1| ≤ |M2| and equals case (b)'s conservative value. Fix the docstrings at
   `demands.jl:43-44, 77-78` and the comment at SY `demands.jl:916-919` accordingly.
4. Flag (separately): steel NLP H1 omits B1; column-group Cm taken from the max-|M2|
   member rather than the governing member.

Deliberately not proposed: implementing Table C-A-8.1 / Eq. C-A-8-2 (commentary, case
figures not in the text layer).

### C.6 Consumers affected

All steel beam and steel column sizing from `design_building` (via
`size_beams!`/`size_columns!` → SS `size_columns` array path), composite beams with
axial compression (`composite_feasibility.jl` reads the same fields), `explain_feasibility`
output, agent diagnosis tool and column swap experiment, `size_steel_members!`
(beams/struts). Expected result: some steel sections get heavier where `Pu_c/Pe1` is
non-trivial; members with `Pu_c = 0` are unchanged.

### C.7 Decisions for the user

1. Approve Cm = 1.0 (§8.2.1(b)) for all non-column steel groups, rather than computing Cm
   "by analysis".
2. For unknown end moments: default `M1 = −M2` (Cm = 1.0), or fail loudly when
   `Pu_c > 0 && Mux > 0` and no `M1/M2` given?
3. Should steel columns ever be flagged `transverse_load = true` (e.g. façade columns with
   wind between floors)? Current models apply no span load to columns.
4. Scope the steel-NLP "no B1" gap and the group-Cm selection issue now or later?

### C.8 Test (task 5)

Hand calc — W10X49 (A992), from the repo catalog
`members/sections/steel/catalogs/data/aisc-shapes-v15.csv:251`: Ix = 272.0 in⁴.
E = 29,000 ksi, L = Lc1 = 14 ft = 168 in (K = 1), LRFD α = 1.0.

- Pe1x = π²·29000·272 / 168² = 77,851,440 / 28,224 = **2758.3 kip** (Eq. A-8-5, EI* = EI
  for the effective-length / first-order method; for the direct analysis method use
  0.8τb·EI).
- Pr = 400 kip ⇒ r = 0.1450.
  - Cm = 1.0 ⇒ B1 = 1/0.8550 = **1.170**.
  - Cm = 0.6 ⇒ 0.6/0.8550 = 0.702 ⇒ B1 = **1.000** (floor at 1).
- Pr = 1200 kip (unit test of B1 only) ⇒ r = 0.4350 ⇒ B1(1.0) = 1.770; B1(0.6) = 1.062;
  ratio 1.667.

Tests to add:
1. Unit: `MemberDemand(1; Pu_c=400kip, Mux=M)` → after fix, `compute_Cm(d.M1x, d.M2x;
   transverse_loading=d.transverse_load) == 1.0`. Fails today (0.6).
2. Checker: a W10X49, L = 14 ft, `Pu_c = 400 kip`, `Mux` chosen so that H1-1a ≈ 0.95 with
   B1 = 1.0; with Cm = 1.0 (B1 = 1.170) it must be infeasible. Compare against
   `_h1_pm_utilizations` with hand-computed amplified moment.
3. Routing: a two-story steel column model with single-curvature column moments
   (same-sign FEM end moments) through `size_columns!` — assert the `MemberDemand`
   reaching `is_feasible` has `M1x ≈ −M2x` (needs a spy or a returned-demand hook).
4. Routing: steel beam group with `Pu_c > 0` through `size_beams!` — assert
   `transverse_load == true` on the checked demand.

---

## Issue D — Mat single-span coefficient

### D.1 Current behavior (file:line)

`StructuralSizer/src/foundations/codes/aci/mat_footing.jl:426-469`
`_rigid_mat_strip_moments(qu, trib_width, spans)`: `w = qu·trib_width`; for each span
`n == 1 → M_neg = wL²/2` (and **`M_pos` stays 0**); end spans `M_neg = wL²/10`,
`M_pos = wL²/11`; interior spans `M_neg = wL²/10`, `M_pos = wL²/12`. Envelope = max over
spans. Docstring (lines 426-445) calls these "ACI approximate moment coefficients",
"cantilever single span uses wL²/2", and cites "aci-336-combined-footings-mats §6.1.2
Step 3" for the full-mat-width convention. The section header (line 423) and the file
header (line 6) label the method "ACI 336.2R-88 §4.2 (Kramrisch strip statics)".

What "span" means here (task 2, from the callers):
- `spans` = `plan.x_spans` / `plan.y_spans` from `_mat_plan_sizing`
  (`mat_footing.jl:166-175`): distances between **unique column coordinates** only
  (`_unique_spans`, lines 30-34). With walls, wall-line coordinates are also supports.
  **Overhangs are not spans**, so `n == 1` means exactly two column lines in that direction
  with one interior span between them.
- Callers: rigid path `mat_footing.jl:785-786` (`trib_width = Lm` for x-strips, `B` for
  y-strips), Shukla rigid envelope `mat_shukla.jl:315-316`.
- Face assignment: rigid path `mat_footing.jl:823-830` — `M_pos → As_bot`,
  `M_neg → As_top`. Shukla `mat_shukla.jl:308-321` — same (`# sagging → As_bot`,
  `# hogging → As_top`).
- Overhang / cantilever: only handled when walls are present
  (`_mat_cantilever_moments`, lines 548-563, "Bottom-tension moment of a clear cantilever,
  `qu · lip² / 2`", maxed into `M_pos`). With no walls, **no cantilever moment is computed
  for the column overhangs** (≥ 2 ft per `_mat_plan_sizing:147`).
- The same moments also drive thickness: `flex_pairs` (line 792) enters
  `_footing_flexure_ok` in the depth search (lines 793-808), so `wL²/2` can raise `h`.
- Single column line in a direction with no walls: `spans` is empty and line 451
  `zero(w * spans[1]^2)` throws `BoundsError` (accidental fail-loud; untested — confirm).
- `RigidMat()` is the default `analysis_method` (`foundations/options.jl:224`).

Winkler path (`foundations/codes/aci/mat_winkler/design.jl:352-357`) does **not** call
`_rigid_mat_strip_moments`; it scales the column-strip-averaged FEA moment intensity by the
full mat width ("Conservative: assumes column-strip intensity across the full width").
Unaffected by the coefficient issue.

### D.2 Code requirement (verbatim + citation)

**ACI 336.2R §6.1.2 Step 3** — `aci-336-combined-footings-mats`, PDF page 11
(printed 336.2R-11). Text is two-column interleaved in the corpus; reassembled:

> "3. Design the reinforcing steel for bending by treating the mat as a rigid body and considering strips both ways, if the following criteria are met:
> a. Column spacing is < 1.75/λ, or the mat is very thick.
> b. Variation in column loads and spacing is not over 20 percent. For mats not meeting this criteria, go immediately to Step 4.
> These strips are analyzed as combined footings with multiple columns loaded with the soil pressure on the strip, and column reactions equal to the factored (or unfactored) loads obtained from the superstructure analysis. Since a mat transfers load horizontally, any given strip may not satisfy a vertical load summation unless consideration is given to the shear transfer between strips. Bowles (1982) illustrates this problem and a method of analysis so the strips satisfy statics."

**ACI 336.2R §5.2 / §5.3** (rigid strip footings), PDF pages 8-9:

> "Continuous strip footings supporting structures which, because of their stiffness, will not allow the individual columns to settle differentially, may be designed using the rigid body assumption with a linear distribution of soil pressure. This distribution can be determined based on statics." (§5.2, p. 8)
>
> "If the average of two adjacent spans in a continuous strip having adjacent loads and column spacings that vary by not more than 20 percent of the greater value, and is less than 1.75/λ, the footing can be considered rigid and the variation of soil pressure determined on the basis of simple statics." (§5.3, p. 9)

§5.5 "Simplified procedure for flexible footings" (Kramrisch and Rogers 1961, Kramrisch 1984)
applies to **flexible** footings with "The minimum number of bays is three" and average
adjacent spans "between the limits 1.75/λ and 3.50/λ" (p. 9) — it is not the rigid method.

Searches of `aci-336-combined-footings-mats` for `coefficient`, `wL`, `column strip`,
`middle strip`, `strip width` found **no moment coefficients and no column/middle-strip
provisions**. ACI 336.2R gives statics, not coefficients.

**ACI 318-11 §8.3.3** — `aci-318-11`, PDF pages 112-113 (printed 108-109):

> "8.3.3 — As an alternate to frame analysis, the following approximate moments and shears shall be permitted for design of continuous beams and one-way slabs (slabs reinforced to resist flexural stresses in only one direction), provided (a) through (e) are satisfied:
> (a) There are two or more spans;
> (b) Spans are approximately equal, with the larger of two adjacent spans not greater than the shorter by more than 20 percent;
> (c) Loads are uniformly distributed;
> (d) Unfactored live load, L, does not exceed three times unfactored dead load, D; and
> (e) Members are prismatic.
> For calculating negative moments, ln is taken as the average of the adjacent clear span lengths."
>
> "Positive moment / End spans / Discontinuous end unrestrained ... wu ln²/11 / Discontinuous end integral with support ... wu ln²/14 / Interior spans ... wu ln²/16 / Negative moments at exterior face of first interior support / Two spans ... wu ln²/9 / More than two spans ... wu ln²/10 / Negative moment at other faces of interior supports ... wu ln²/11 / Negative moment at face of all supports for Slabs with spans not exceeding 10 ft; and beams where ratio of sum of column stiffnesses to beam stiffness exceeds 8 at each end of the span ... wu ln²/12 / Negative moment at interior face of exterior support for members built integrally with supports / Where support is spandrel beam ... wu ln²/24 / Where support is a column ... wu ln²/16"

(ACI 318-19 §6.5.1 / Table 6.5.2, `aci-318-19` PDF p. 76, carries the same five conditions —
"(d) There are at least two spans" — but the table values are garbled in the text layer, so
318-11 is quoted.)

**ACI 318-11 §15.10** — `aci-318-11`, PDF page 277 (printed 273):

> "15.10.2 — The direct design method of Chapter 13 shall not be used for design of combined footings and mats.
> 15.10.3 — Distribution of soil pressure under combined footings and mats shall be consistent with properties of the soil and the structure and with established principles of soil mechanics.
> 15.10.4 — Minimum reinforcing steel in nonprestressed mat foundations shall meet the requirements of 7.12.2 in each principal direction. Maximum spacing shall not exceed 18 in."

### D.3 Gap (task 3, 4)

1. **The coefficients are not from the cited source.** ACI 336.2R §6.1.2 Step 3 prescribes
   rigid-body strip **statics** with column loads as known forces; it gives no coefficients
   and no width convention. The wL²/10, /11, /12 values are a beam analogy borrowed from
   ACI 318 §8.3.3, whose scope is "continuous beams and one-way slabs" and which needs
   "two or more spans". Applying it to a mat strip is ENGINEERING JUDGMENT and must be
   labeled that way. Two code-level mismatches even within that analogy:
   - Two spans (n = 2): first-interior negative moment is **wu ln²/9**, the code uses
     wL²/10 (10 % low).
   - Interior positive: §8.3.3 gives wu ln²/16; code uses wL²/12 (conservative). Code uses
     centre-to-centre spans, not clear spans (conservative).
2. **n == 1 (two column lines, one span): wL²/2 is a misapplied cantilever formula.** It is
   the fixed-end moment of a cantilever of length L, which corresponds to no element of
   this geometry. §8.3.3(a) excludes one span, so the source is silent on coefficients;
   ACI 336.2R says statics. Rigid-body statics for two equal column-line loads, uniform
   pressure, overhang `a` each side (derivation by hand — **not a quoted source**):
   - at each column line (cantilever, bottom tension): `w·a²/2`;
   - at midspan (top tension): `w·(L²/8 − a²/2)`.
   So the code's top-face moment wL²/2 is **≥ 4×** the statics value (conservative, and it
   can inflate `h` via `_footing_flexure_ok`), and its bottom-face moment is **0** where
   statics gives `w·a²/2` (unconservative unless minimum steel covers it; no-wall mats only).
3. **Face assignment for n ≥ 2 looks inverted (needs user confirmation).** Net soil pressure
   acts upward and column loads downward, so a mat strip is the inverted beam: support
   (column-line) moments put the **bottom** in tension and span moments put the **top** in
   tension. The file already uses that reading for wall cantilevers ("Bottom-tension
   moment ... maxed into `M_pos`") and for bottom-bar development at column faces
   (`_mat_flexure_avails`, lines 625-633). But the strip routine follows the downward-beam
   naming: the support coefficient (wL²/10) goes to `M_neg → As_top` and the span
   coefficient (wL²/11, /12) to `M_pos → As_bot`. If the inverted-beam reading is accepted,
   bottom steel is short by 10/11 (end spans), 10/12 (interior), 9/11 (two spans) — about
   9 % to 18 % less moment than needed — and top steel is correspondingly over-designed.
4. **Coefficients vs. the statics Step 3 actually asks for.** Step 3 admits column loads
   within 20 %. With equal column loads, rigid uniform pressure and column loads as given
   forces, statics gives much larger interior top-tension moments than the beam
   coefficients. Hand statics (by hand, not a quoted source), L = 24 ft spans, a = 3 ft, w
   per unit strip length:
   - 2 spans (3 lines, P = 18w each): max top tension 108w at x = 18 ft (wL²/5.3). The code
     gives top wL²/10 = 57.6w, so it is **1.9× low**.
   - 3 spans (4 lines, P = 19.5w each): top tension 175.5w at the centre (wL²/3.3). The code
     gives 57.6w, so it is **3.0× low**.
   The beam coefficients assume exterior reactions of roughly 0.4-0.6 of the interior ones,
   which the 20 % load-variation gate rules out. ACI 336.2R itself warns that strips "may
   not satisfy a vertical load summation" and points to Bowles (1982) (not in the corpus).
   This is the largest potential unconservatism in Issue D. The physics needs user review
   before anything is built on it.
5. **Full-width × worst-span intensity (task 4).** Not stated in §6.1.2 Step 3 (the quoted
   text has no width rule). With uniform `qu` and per-unit-width strip moments, worst
   intensity × full width is **at least** the sum over strips (equal when every strip has
   the same spans), so the total steel is not under-counted. However ACI 336.2R says
   **nothing** about column versus middle strips, and ACI 318-11 §15.10.2 bars the
   Chapter 13 direct design method (its column/middle-strip split) for mats. Spreading the
   steel uniformly across the width leaves less steel near the column lines than a plate
   solution would put there. That concentration is not grounded in the corpus for the rigid
   method. Treat it as ENGINEERING JUDGMENT; Winkler/Shukla (Step 4) are the corpus-endorsed
   check ("revise the rigid body design as necessary").
6. Labeling: "Kramrisch strip statics" is a mislabel. Kramrisch appears in §5.5 for
   flexible footings with three or more bays, not in the rigid Step 3. The docstring's
   §6.1.2 Step 3 citation for the full-width convention is ungrounded.

### D.4 Proposed change

Code-derived (cite `aci-336-combined-footings-mats` §6.1.2 Step 3, PDF p. 11; §5.2, p. 8):
1. Replace the coefficients with **rigid-body strip statics**. Take a strip of full width
   (or per column line), uniform or linear `qu`, column-line loads as known downward forces
   and overhangs included. Take the signed moment diagram along the strip:
   max bottom-tension → `As_bot`, max top-tension → `As_top`. This covers n = 1, the
   overhang cantilevers and the face assignment in one go, and it is what Step 3 describes.
   For the vertical-summation mismatch between strips, a method is needed (Bowles 1982 is
   not in the corpus) — **user decision**.
2. Empty `spans` (single column line, no walls): cantilever statics from the column line to
   both edges instead of the current `BoundsError`; or fail loudly with a clear message.

ENGINEERING JUDGMENT alternatives (if coefficients are kept):
3. Keep §8.3.3 coefficients only for n ≥ 2, with the two-span wL²/9, labeled as judgment
   (§8.3.3 is for beams/one-way slabs). Put the support coefficient on the **bottom** face
   and the span coefficient on the **top** face. Add an explicit overhang cantilever
   `qu·a²/2` (bottom) per direction in the no-wall case.
4. For n = 1 there is no coefficient source. Use statics (`w·a²/2` bottom,
   `w·(L²/8 − a²/2)` top, with a floor at 0 and the larger of the two cases if `a` varies),
   or keep the current wL²/2 top as a deliberately conservative bound. Either way bottom
   still needs the cantilever.
5. Fix docstrings/headers: drop "Kramrisch", drop the §6.1.2 citation for full width, mark
   the coefficient basis as judgment.

### D.5 Consumers affected

`design_footing(::MatFoundation)` with `RigidMat()` (default, `options.jl:224`) and
`ShuklaAFM()` (rigid envelope); SY callers `analyze/foundations/size_isolated.jl:90`,
`analyze/foundations/wall_groups.jl:562`, API deserialization
(`api/deserialize/foundations.jl:62-66`, which maps unknown strings to `RigidMat()` —
separate fail-loud issue). `WinklerFEA` unaffected, including the rigid → Winkler fallback.
Thickness `h` (via `_footing_flexure_ok`), `As_*`, bar counts, development checks and
`Kr`-based rigidity gating all move.

### D.6 Decisions for the user

1. Accept rigid strip statics (Step 3 literal) in place of beam coefficients? If yes, how
   should the strip vertical-summation mismatch be handled (column loads as given vs.
   averaged reactions — a Bowles-type adjustment, source not in the corpus)?
2. Confirm the inverted-beam face reading: column lines → bottom tension, spans → top
   tension.
3. For n = 1: statics or conservative wL²/2 for the top face? Always add the overhang
   cantilever for the bottom face?
4. Is uniform distribution over the full width acceptable for the rigid method, or should
   steel be concentrated in column bands (no corpus source for the rigid method)?
5. Single-column-line mats with no walls: implement cantilever statics or keep failing?

### D.7 Test (task 5)

Hand calc 1 — two column lines (n = 1), no walls. 2×2 grid, 24 ft × 24 ft, user
`edge_overhang = 3 ft`, Pu = 500 kip per column ⇒ B = Lm = 30 ft, `qu = 2000/900 = 2.222 ksf`.
x-strip full width: w = 2.222 × 30 = 66.67 kip/ft.
- Current code: `M_neg = wL²/2 = 66.67 × 576 / 2 = 19,200 kip·ft` (top), `M_pos = 0` (bottom).
- Statics: column line `w·a²/2 = 66.67 × 9 / 2 = 300 kip·ft` (bottom); midspan
  `w(L²/8 − a²/2) = 66.67 × 67.5 = 4,500 kip·ft` (top). Free-body check at x = 15 ft:
  soil 1000 kip × 7.5 ft = 7,500; column line 1000 kip × 12 ft = 12,000 ⇒ 4,500 kip·ft,
  top in tension.
- Test: `_rigid_mat_strip_moments(2.222ksf, 30ft, [24ft])` → today `(0, 19200)`; after
  the fix it should give bottom 300 and top 4,500 kip·ft (statics option).

Hand calc 2 — two spans, equal loads (3 lines, L = 24 ft, a = 3 ft, P = 18w per line):
the statics top-tension maximum is 108w at 18 ft from the left edge. The code gives
wL²/10 = 57.6w (top) and wL²/11 = 52.4w (bottom); §8.3.3 (two spans) would give
wL²/9 = 64w. A regression test should pin whichever basis the user picks.

Hand calc 3 — three spans, equal loads (4 lines, P = 19.5w): centre top tension 175.5w;
the code gives 57.6w.

Other tests: the n = 1 bottom face must not be 0 when overhang > 0 (no walls); the
single-column-line no-wall mat must fail loudly or produce cantilever statics (assert
whichever behavior is chosen); the Shukla rigid envelope must pick up the corrected moments.

---

Status: COMPLETE (research only).
