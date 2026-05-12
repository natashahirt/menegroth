# Flat Plate / Flat Slab (ACI 318)

> ```julia
> using StructuralSizer
> using Unitful
>
> # Method presets
> opts_ddm = FlatPlateOptions(method = DDM())  # full DDM (default)
> opts_efm = FlatPlateOptions(method = EFM())
> opts_fea = FlatPlateOptions(method = FEA())
>
> method_name(opts_ddm.method)                 # "DDM (ACI 8.10)"
> h_min = min_thickness(FlatPlate(), 20.0u"ft")  # ACI minimum thickness
> ```

## Overview

The flat plate module implements the full ACI 318 two-way slab design pipeline
for flat plates and flat slabs (with drop panels). Moment analysis is performed
using a typed analysis method (`DDM`, `EFM`, or `FEA`), and the resulting moment
envelopes feed into a shared reinforcement, punching shear, and deflection workflow.

The design is iterative: slab thickness grows until deflection, punching, and
flexural adequacy are simultaneously satisfied.

### Analysis Methods Summary

| Method | Symbol | Description | When to Use |
|:-------|:-------|:------------|:------------|
| `DDM()` | `:ddm` | Direct Design Method | Regular grids, quick estimates |
| `DDM(:simplified)` | `:mddm` | Modified DDM | Simplified coefficients |
| `EFM()` | `:efm` | Equivalent Frame Method | Irregular geometry, final design |
| `FEA()` | `:fea` | Shell Finite Element Analysis | Irregular layouts, large grids, shell-level accuracy |
| `RuleOfThumb()` | — | Single-pass at ACI minimum thickness | Fast screening (checks may fail; no iteration) |

**DDM** uses ACI 318 Table 8.10 coefficients — fast but requires regular geometry (aspect ratio, load limits). **EFM** builds an Asap frame model and distributes moments by stiffness — handles irregular geometry with more accurate results. **FEA** uses a 2D shell mesh with column stubs and supports pattern loading; see [FEA — Shell Finite Element Analysis](#fea--shell-finite-element-analysis) below for options.

### Design Workflow

```
Phase A: Moment Analysis (method-specific)
├── DDM: ACI coefficient tables → static moment → column/middle strip
├── EFM: Asap frame model → moment distribution → column/middle strip
└── FEA: Shell mesh + column stubs → section cuts or Wood–Armer → strips

Phase B: Slab Design (shared)
├── Column P-M interaction design (iterates with slab)
├── Punching shear check (Vu + γv×Mub)
├── Two-way deflection (crossing beam method)
├── One-way shear check
├── Reinforcement design (flexure + minimum)
└── Integrity reinforcement (ACI 8.7.4.2)
```

**Source:** `StructuralSizer/src/slabs/codes/concrete/flat_plate/`

## Key Types

```@docs
MomentAnalysisResult
EFMSpanProperties
EFMJointStiffness
DDMApplicabilityError
EFMApplicabilityError
EFMModelCache
FEAModelCache
SpanInfo
PanelStripGeometry
ColumnStripPolygon
MiddleStripPolygon
DropPanelGeometry
DropSectionProperties
StripReinforcementDesign
```

See also `FlatPlatePanelResult`, `PunchingCheckResult`,
`StripReinforcement`, `ShearStudDesign`,
`ClosedStirrupDesign`, `ShearCapDesign`, and
`ColumnCapitalDesign` in [Slab Types & Options](../../types.md).

## Functions

### Pipeline

```@docs
run_secondary_moment_analysis
```

### DDM (Direct Design Method)

Dispatched via `run_moment_analysis(::DDM, ...)`. Low-level coefficient
functions (`total_static_moment`, `distribute_moments_aci`,
`distribute_moments_mddm`) are exported for standalone use.

### EFM (Equivalent Frame Method)

```@docs
build_efm_asap_model
solve_efm_frame!
extract_span_moments
```

### FEA (Finite Element Analysis)

Dispatched via `run_moment_analysis(::FEA, ...)`.  No separate public API beyond
the FEA analysis-method type.

### Design Checks

```@docs
check_punching_for_column
check_punching_at_drop_edge
check_punching
```

### Reinforcement

```@docs
design_strip_reinforcement
design_strip_reinforcement_fea
design_single_strip
transfer_reinforcement
integrity_reinforcement
```

### Punching Shear Reinforcement

```@docs
design_shear_studs
design_closed_stirrups
design_shear_cap
design_column_capital
```

### Column Growth

```@docs
solve_column_for_punching
grow_column!
```

## Implementation Details

### Analysis Methods

#### DDM — Direct Design Method (ACI 318)

The total factored static moment for each span is:

```math
M_0 = \frac{q_u \, l_2 \, l_n^2}{8}
```

where ``q_u`` is the factored uniform load, ``l_2`` is the transverse span, and
``l_n`` is the clear span (ACI §8.10.3.2).

Longitudinal distribution uses the ACI Table 8.10.4.2 coefficients:

| Location       | End span (exterior neg) | End span (positive) | End span (interior neg) | Interior neg | Interior pos |
|:---------------|:-----------------------:|:-------------------:|:-----------------------:|:------------:|:------------:|
| **Full DDM**   | 0.26                    | 0.52                | 0.70                    | 0.65         | 0.35         |
| **Simplified** | 0.65                    | 0.35                | 0.65                    | 0.65         | 0.35         |

Transverse distribution to column and middle strips follows ACI §8.10.5, with
edge-beam torsional stiffness ratio ``β_t`` interpolating the exterior negative
moment fraction between 0.26 and 0.30.

**Applicability** is checked per ACI §8.10.2: ≥ 3 spans each direction, span
ratio ≤ 2, successive span lengths within 1/3, column offsets ≤ 10%, and
gravity-only loading.

Two variants are supported:
- `:full` — Full ACI 318 Table 8.10.4.2 coefficients with ``l_2/l_1``
  interpolation and per-span exterior/interior classification.
- `:simplified` — Modified DDM with 0.65/0.35 fixed split (conservative for
  preliminary design).

#### EFM — Equivalent Frame Method (ACI 318)

An equivalent frame is constructed along one direction with:

- **Slab-beam stiffness** \(K_{sb}\) from PCA Table A1 (non-prismatic for drop
  panels, using `pca_slab_beam_factors_np`)
- **Column stiffness** \(K_c\) from PCA Table A7 (optionally cracked, \(0.70\,I_g\)
  per ACI §10.10.4.1)
- **Torsional member stiffness** \(K_t = \frac{9\,E_c\,C}{l_2\,(1 - c_2/l_2)^3}\)
- **Equivalent column stiffness** \(K_{ec} = \frac{K_c \cdot K_t}{K_c + K_t}\)

Two solvers are available:
- `:asap` — Builds an Asap `FrameModel` with rigid-zone-enhanced elements
  (3 sub-elements per span).  Sections and loads are updated in-place across
  iterations via `EFMModelCache`.
- `:hardy_cross` — Iterative moment distribution (for cross-validation with
  StructurePoint).

**Column stiffness modes:**
- `:Kec` (default) — Standard EFM with torsional reduction.
- `:Kc` — Raw column stiffness without torsion; isolates the torsional effect
  and provides a comparison point with FEA.

**Pattern loading** is activated when ``L/D > 0.75`` (ACI §13.7.6).  The
envelope includes checkerboard, adjacent-span, and all-loaded patterns.

Face-of-support moment reduction (ACI §8.11.6.1) is applied after solving.

#### FEA — Shell Finite Element Analysis

A 2D shell mesh with column stubs is solved for dead and live loads separately
(ASCE 7 §2.3.1).  Design approaches:

| Approach  | Description |
|:----------|:------------|
| `:frame`  | Integrate moments across full frame width, then distribute to column/middle strips using ACI 8.10.5 tabulated fractions |
| `:strip`  | Integrate moments directly over column-strip and middle-strip widths via section cuts |
| `:area`   | Per-element design with Wood–Armer moment transformation |

The **Wood–Armer** transform (Wood 1968) converts ``M_x, M_y, M_{xy}`` into
equivalent design moments ``M_x^*, M_y^*`` that account for torsion.  An
optional **concrete torsion discount** subtracts the ACI-based concrete torsion
capacity from ``|M_{xy}|`` before applying the transformation (Parsekian 1996).

**Moment transform options:**
- `:projection` — Project tensor onto reinforcement axis:
  ``M_n = M_{xx}\cos^2\theta + M_{yy}\sin^2\theta + M_{xy}\sin 2\theta``
- `:wood_armer` — Conservative Wood–Armer transformation
- `:no_torsion` — Intentionally unconservative baseline (ignores ``M_{xy}``)

**Field smoothing:** `:element` (raw centroid moments) or `:nodal`
(area-weighted SPR smoothing).  For nodal smoothing, `sign_treatment` can be
`:signed` (standard SPR) or `:separate_faces` (prevents cross-sign cancellation
at inflection points).

**Section cut methods:** `:delta_band` (adaptive bandwidth δ-band) or
`:isoparametric` (line-integral cuts through quad cells, with blending parameter
`iso_alpha ∈ [0, 1]`).

**Pattern loading modes:**
- `:efm_amp` — One FEA solve + many cheap EFM solves for amplification factors.
- `:fea_resolve` — Full re-solve for each load pattern (more accurate, slower).

### Punching Shear (ACI 318)

Critical section geometry is computed at ``d/2`` from the column face:

- **Interior:** 4-sided, ``b_0 = 2(c_1 + d) + 2(c_2 + d)``
- **Edge:** 3-sided, closed at the slab edge
- **Corner:** 2-sided, two free edges

Nominal shear stress capacity (ACI §11.11.2.1):

```math
v_c = \min\left( 4\lambda\sqrt{f'_c},\; \left(2 + \frac{4}{\beta}\right)\lambda\sqrt{f'_c},\; \left(\frac{\alpha_s d}{b_0} + 2\right)\lambda\sqrt{f'_c} \right)
```

where \(\beta = c_{\text{long}} / c_{\text{short}}\), and \(\alpha_s = 40\) (interior), 30 (edge), 20 (corner).

Combined shear stress from direct shear and unbalanced moment transfer
(ACI R11.11.7.2):

```math
v_u = \frac{V_u}{b_0 d} + \frac{\gamma_v M_{ub} \, c_{AB}}{J_c}
```

Moment transfer fraction \(\gamma_v = 1 - \gamma_f\), where
\(\gamma_f = 1 / (1 + \frac{2}{3}\sqrt{b_1/b_2})\) (ACI Eq. 13-1).

When punching fails, four remediation strategies are attempted in configurable
order:
- **Headed shear studs** (§11.11.5): Per Ancon Shearfix catalog, ``v_{cs} = 3\lambda\sqrt{f'_c}``
  concrete contribution, ``v_s = A_v f_{yt} / (b_0 s)`` steel contribution,
  maximum ``v_n \leq 8\sqrt{f'_c}``
- **Closed stirrups** (§11.11.3): ``v_{cs}`` capped at ``2\lambda\sqrt{f'_c}``,
  ``v_n \leq 6\sqrt{f'_c}``
- **Shear caps** (§13.2.6): Localized thickening with extent ≥ projection depth
- **Column capitals** (§13.1.2): Flared column heads with 45° cone/pyramid rule

### Deflection (ACI §24.2)

The flat-plate pipeline uses **Branson's** effective moment of inertia by default (`effective_moment_of_inertia`, ACI Eq. 9-10). For FEA-based analysis, you can opt into the **Bischoff (2005)** reciprocal formulation by setting `FEA(deflection_Ie_method = :bischoff)`.

Bischoff's formulation is:

```math
I_e = \frac{I_{cr}}{1 - \left(\frac{M_{cr}}{M_a}\right)^2 \left(1 - \frac{I_{cr}}{I_g}\right)}
```

Branson's formulation (ACI Eq. 9-10) is:

```math
I_e = \left(\frac{M_{cr}}{M_a}\right)^3 I_g + \left[1 - \left(\frac{M_{cr}}{M_a}\right)^3\right] I_{cr}
```

Long-term deflection multiplier: \(\lambda_\Delta = \xi / (1 + 50\rho')\), with \(\xi = 2.0\) for loads sustained ≥ 5 years.

For flat slabs with drop panels, ``I_e`` is computed at midspan (slab-only
section) and at supports (composite drop + slab section), then weighted per
ACI 435R-95 Eq. 4-1a,b:

```math
I_e = 0.70\,I_{e,m} + 0.15\,(I_{e,1} + I_{e,2})
```

Panel deflection uses the PCA crossing-beam method: frame-strip deflections in
each direction are combined to estimate total panel deflection.

**Limits:** ``L/360`` (live load), ``L/240`` (total), ``L/480`` (sensitive
partitions).

### Design Pipeline

The pipeline (`size_flat_plate!`) runs in three phases:

**Phase A — Depth convergence:**
1. Moment analysis (DDM / EFM / FEA)
2. Column P–M design → update column sizes; re-run if changed
3. Two-way deflection check → increase ``h`` if failed
4. One-way shear check → increase ``h`` if failed
5. Flexural adequacy (tension-controlled, ACI §21.2.2) → increase ``h`` if failed

**Phase B — Punching resolution:**
1. Punching check at each column
2. Resolve failures by strategy (`:grow_columns`, `:reinforce_first`, `:reinforce_last`)
3. Re-run moment analysis if columns grew

**Phase C — Final design:**
1. Face-of-support moment reduction (EFM only, ACI §8.11.6.1)
2. Strip reinforcement design (ACI §8.10.5 transverse distribution)
3. Moment transfer reinforcement (ACI §8.4.2.3)
4. Structural integrity bars (ACI §8.7.4.2)
5. Build `FlatPlatePanelResult`

If Phase B or C requires additional depth, ``h`` is incremented and Phase A
restarts.  Default maximum iterations: 10 per phase.

### Initial Estimates

- Thickness from ACI Table 8.3.1.1: ``l_n/33`` (flat plate interior),
  ``l_n/30`` (exterior), ``l_n/36`` / ``l_n/33`` (flat slab)
- Fire rating override from ACI 216.1-14 if specified
- Column size from \(\text{span}/15\) or tributary area

## Key Functions

| Function | Description | API Level |
|:---------|:-----------|:----------|
| `size_flat_plate!` | Full design pipeline | Internal (called by `size_slab!`) |
| `run_moment_analysis(::DDM, ...)` | DDM moment analysis | Internal |
| `run_moment_analysis(::EFM, ...)` | EFM moment analysis | Internal |
| `run_moment_analysis(::FEA, ...)` | FEA moment analysis | Internal |
| `check_punching` | ACI 318 punching check (shared slab/foundation utilities) | Exported |
| `design_strip_reinforcement` | Flexure + minimum As | Exported |

## Results Access

`FlatPlatePanelResult` is returned per panel. Key fields:

```julia
panel = result  # :: FlatPlatePanelResult

# Geometry & loads
panel.thickness               # Final slab depth
panel.l1                      # Primary span
panel.l2                      # Transverse span
panel.M0                      # Total static moment

# Reinforcement (per strip)
panel.column_strip_reinf      # :: StripReinforcement — primary column strip
panel.middle_strip_reinf      # :: StripReinforcement — primary middle strip
panel.secondary_column_strip_reinf
panel.secondary_middle_strip_reinf

# Punching shear
panel.punching_check.ok       # All columns pass?
panel.punching_check.max_ratio
punching_ok(panel)            # Helper accessor

# Deflection
panel.deflection_check.ok     # Within limit?
panel.deflection_check.ratio
deflection_ok(panel)          # Helper accessor
```

## Options & Configuration

See also `FlatPlateOptions` and `FlatSlabOptions` in
[Slab Types & Options](../../types.md).

### FlatPlateOptions

```julia
FlatPlateOptions(
    material = RC_4000_60,       # Concrete + rebar bundle
    cover = 19.05u"mm",          # Clear cover (0.75")
    bar_size = 5,                # Typical bar (#3-#11)
    method = DDM(),              # DDM(), EFM(), FEA(), or RuleOfThumb()
    has_edge_beam = false,       # Spandrel beam at exterior?
    φ_flexure = 0.90,            # Tension-controlled (ACI Table 21.2.1)
    φ_shear = 0.75,              # Shear and torsion
    λ = nothing,                  # Lightweight factor (nothing → auto from material)
    deflection_limit = :L_360,   # :L_240, :L_360, :L_480
)
```

Key `FlatPlateOptions` fields:

| Field | Default | Description |
|:------|:--------|:------------|
| `method` | `DDM()` | Analysis method (`DDM`, `EFM`, `FEA`, `RuleOfThumb`) |
| `has_edge_beam` | `false` | Whether an exterior spandrel beam is present (affects DDM/EFM edge distribution) |
| `edge_beam_βt` | `nothing` | Explicit edge-beam torsional stiffness override (when not `nothing`) |
| `grouping` | `:by_floor` | How to group slabs for envelope sizing: `:individual`, `:by_floor`, `:building_wide` |
| `punching_strategy` | `:grow_columns` | Punching failure resolution order |
| `punching_reinforcement` | `:headed_studs_generic` | Punching reinforcement type |
| `max_column_size` | `30.0u"inch"` | Maximum column size before bumping thickness (or using reinforcement, depending on strategy) |
| `stud_material` | `Stud_51` | Shear stud / stirrup steel material |
| `stud_diameter` | `0.5u"inch"` | Headed stud diameter (stud-based reinforcement only) |
| `stirrup_bar_size` | `4` | Stirrup bar size (closed stirrups only) |
| `min_h` | `nothing` | Minimum slab thickness override (`nothing` → use ACI Table 8.3.1.1 minimums) |
| `objective` | `MinVolume()` | Optimization objective |
| `col_I_factor` | `0.70` | Column cracked Ig factor (ACI §10.10.4.1) |

Key `size_flat_plate!` keyword arguments:

| Kwarg | Default | Description |
|:------|:--------|:------------|
| `max_iterations` | `10` | Convergence loop limit |
| `column_tol` | `0.05` | Column size convergence tolerance |
| `h_increment` | `0.5u"inch"` | Slab thickness growth step |

Key `FEA` options:

| Field | Default | Description |
|:------|:--------|:------------|
| `target_edge` | `nothing` | Target mesh edge length (`Length` or `nothing` for adaptive sizing) |
| `pattern_loading` | `true` | ACI 318-11 §13.7.6 pattern loading |
| `pattern_mode` | `:efm_amp` | `:efm_amp` (one FEA + cheap EFM factors) or `:fea_resolve` (full re-solve per pattern) |
| `design_approach` | `:frame` | `:frame`, `:strip`, or `:area` |
| `moment_transform` | `:projection` | `:projection`, `:wood_armer`, `:no_torsion` |
| `field_smoothing` | `:element` | `:element` (raw centroids) or `:nodal` (area-weighted SPR smoothing) |
| `cut_method` | `:delta_band` | `:delta_band` or `:isoparametric` |
| `iso_alpha` | `1.0` | Isoparametric cut blending parameter `[0, 1]` |
| `rebar_direction` | `nothing` | Reinforcement axis angle (radians); `nothing` = span direction |
| `sign_treatment` | `:signed` | `:signed` or `:separate_faces` (prevents cross-sign cancellation at inflection points) |
| `concrete_torsion_discount` | `false` | Subtract concrete Mxy capacity before Wood–Armer |
| `patch_stiffness_factor` | `1.0` | Column patch stiffness multiplier |
| `deflection_Ie_method` | `:branson` | `:branson` or `:bischoff` |

!!! note "Drop Panel Strip Widening"
    When a `DropPanelGeometry` is present, column-strip polygons are automatically
    widened so their transverse extent covers the drop panel zone.  The minimum
    column-strip half-width becomes `max(d_max/2, a_drop)`, where `a_drop` is the
    drop panel half-extent (Pacoste §4.2.1 Fig 4.4).

## Limitations & Future Work

- **DDM** is restricted to regular grids satisfying ACI §8.10.2; irregular
  layouts require EFM or FEA.
- **EFM pattern loading** generates all ``2^n`` load combinations for ``n``
  spans, which grows exponentially.  Large grids should use FEA with
  `:efm_amp`.
- **FEA** does not yet support post-tensioned slabs or staged construction.
- Punching at re-entrant corners and openings near columns is not checked.
- Punching reinforcement catalogs are hard-coded (`:headed_studs_generic`, `:headed_studs_incon`, `:headed_studs_ancon`);
  user-defined catalogs are planned.
- The `RuleOfThumb` method uses ACI min thickness without iteration—design checks
  are reported but may fail.

## References

- ACI 318 (Two-Way Slabs)
- StructurePoint DE-Two-Way-Flat-Plate Example
- PCA Notes on ACI 318 (stiffness factors)
