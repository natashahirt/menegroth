# AISC 360-16: W Shapes

> ```julia
> using StructuralSizer
> w = W("W14X22")
> mat = A992_Steel
> ϕMn = get_ϕMn(w, mat; Lb=12u"ft", Cb=1.0)
> ϕPn = get_ϕPn(w, mat, 12u"ft")
> println("ϕMn = $ϕMn, ϕPn = $ϕPn")
> ```

## Overview

This module implements AISC 360-16 capacity checks for doubly-symmetric I-shapes (W, S, M, HP sections). It covers compression (Chapter E), flexure (Chapter F), shear (Chapter G), torsion (AISC Design Guide 9), tension (Chapter D), P-M interaction (Chapter H), slenderness classification (Table B4.1), moment amplification (Appendix 8 B1/B2), and **composite beam design (Chapter I)**.

The `AISCChecker` type dispatches capacity calculations based on section type. For `ISymmSection`, the functions in this module are called. See also:
- [Generic Provisions](generic.md) — tension, interaction, moment amplification (all section types)
- [HSS Rectangular](hss_rect.md) / [HSS Round](hss_round.md) — hollow sections
- [Fire](fire.md) — fire protection sizing

Source: `StructuralSizer/src/members/codes/aisc/i_symm/*.jl`

## Design Philosophy

- **LRFD only** — ASD (Ω factors) not implemented
- **US/SI units via Unitful** — functions accept any consistent unit; conversions are automatic
- **Member-level design** — no system-level checks (diaphragm, stability bracing)
- **Catalog-based optimization** — sections must come from predefined catalogs

## Units & Input Flexibility

The API accepts **any Unitful quantity** — conversions happen internally:

```julia
using StructuralSizer: kip  # Asap custom unit

# All equivalent — units converted internally to SI (N, N·m)
size_columns([500u"kN"], [100u"kN*m"], geoms, SteelColumnOptions())
size_columns([112.4kip], [73.76kip*u"ft"], geoms, SteelColumnOptions())
size_columns([500e3], [100.0], geoms, SteelColumnOptions())  # Raw Float64 assumed N, N·m
```

Unit helpers: `to_newtons(x)`, `to_newton_meters(x)` for SI; `to_kip(x)`, `to_kipft(x)` for US customary. Raw `Real` values pass through as-is (assumed correct units).

## Quick Start

```julia
using StructuralSizer
using Unitful

section = W("W14X22")
material = A992_Steel

ϕPn = get_ϕPn(section, material, 12u"ft"; axis=:weak)      # Compression (Ch. E)
ϕMn = get_ϕMn(section, material; Lb=12u"ft", Cb=1.0)       # Flexure (Ch. F)
ϕVn = get_ϕVn(section, material; axis=:strong)              # Shear (Ch. G)
ϕPn_t = get_ϕPn_tension(section, material)                  # Tension (Ch. D)

ratio = check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)
# ratio ≤ 1.0 → OK
```

## Key Types

`AISCChecker <: AbstractCapacityChecker` carries LRFD resistance factors and design preferences. See [AISC — HSS Rect](hss_rect.md) for the `@docs` entry.

| Field | Default | Description |
|:------|:--------|:------------|
| `ϕ_b` | 0.9 | Flexure resistance factor |
| `ϕ_c` | 0.9 | Compression resistance factor |
| `ϕ_v` | 1.0 | Shear resistance factor (rolled shapes) |
| `ϕ_t` | 0.9 | Tension resistance factor |
| `deflection_limit` | `nothing` | L/Δ limit (e.g. 360.0 for L/360) |
| `max_depth` | `Inf` | Maximum section depth constraint |
| `prefer_penalty` | 1.0 | Penalty multiplier for non-preferred sections |

## Functions

### Flexure (AISC §F2, §F3, §F6)

`get_ϕMn` and `get_Mn` dispatch on `ISymmSection` for W-shape-specific flexure. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕMn(s::ISymmSection, mat; Lb, Cb=1.0, axis=:strong, ϕ=0.9)` — returns the design flexural strength.

`get_Mn(s::ISymmSection, mat; Lb, Cb=1.0, axis=:strong)` — returns the nominal flexural strength. For strong-axis bending, this is the minimum of:

1. **Yielding (F2-1):** ``M_p = F_y \times Z_x``
2. **Lateral-torsional buckling (F2-2, F2-3, F2-4):** depends on ``L_b`` relative to ``L_p`` and ``L_r``
3. **Flange local buckling (F3-1, F3-2):** for noncompact or slender flanges

For weak-axis bending (§F6): ``M_p = \min(F_y Z_y,\; 1.6\,F_y S_y)`` with FLB reductions for noncompact/slender flanges.

```@docs
get_Lp_Lr
```

`get_Lp_Lr(s, mat)` — limiting unbraced lengths for LTB:

```math
L_p = 1.76\,r_y\sqrt{\frac{E}{F_y}} \qquad \text{(F2-5)}
```

``L_r`` from Eq. F2-6 using ``r_{ts}``, ``J``, ``S_x``, ``h_o``.

```@docs
get_Fcr_LTB
```

`get_Fcr_LTB(s, mat, Lb; Cb)` — elastic LTB critical stress (F2-4):

```math
F_{cr} = \frac{C_b \pi^2 E}{\left(\dfrac{L_b}{r_{ts}}\right)^2} \sqrt{1 + 0.078 \frac{Jc}{S_x h_o} \left(\frac{L_b}{r_{ts}}\right)^2}
```

### Compression (AISC §E3, §E4, §E7)

`get_ϕPn` and `get_Pn` dispatch on `ISymmSection` for W-shape-specific compression. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕPn(s::ISymmSection, mat, L; axis=:weak, ϕ=0.90)` — design compressive strength.

`get_Pn(s::ISymmSection, mat, L; axis=:weak)` — nominal compressive strength. Considers:
- Flexural buckling (E3) about the governing axis
- Flexural-torsional buckling (E4) for doubly-symmetric sections
- Local buckling reductions via Q factor (E7) for slender elements

Critical stress per E3-2/E3-3:

```math
F_{cr} = \begin{cases} 0.658^{F_y/F_e} \, F_y & F_y/F_e \leq 2.25 \\ 0.877\,F_e & F_y/F_e > 2.25 \end{cases}
```

`get_Fe_flexural(s, mat, L; axis)` — Euler buckling stress (E3-4):

```math
F_e = \frac{\pi^2 E}{\left(\dfrac{KL}{r}\right)^2}
```

`get_Fe_torsional(s, mat, Lz)` — torsional/flexural-torsional buckling stress (E4-4).

### Shear (AISC §G2)

`get_ϕVn` and `get_Vn` dispatch on `ISymmSection` for W-shape-specific shear. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕVn(s::ISymmSection, mat; axis=:strong, ϕ=nothing)` — design shear strength. Default `ϕ = 1.0` for rolled shapes per G2.1(a).

`get_Vn(s::ISymmSection, mat; axis=:strong)` — nominal shear strength (G2-1):

```math
V_n = 0.6\,F_y\,A_w\,C_{v1}
```

where ``A_w = d \times t_w`` (full-depth web area per AISC §G2.1).

```@docs
get_Cv1
```

`get_Cv1(s, mat; kv=5.34, rolled=true)` — web shear coefficient per G2.1. For rolled shapes with `h/tw ≤ 2.24√(E/Fy)`, `Cv1 = 1.0`.

### Torsion (AISC Design Guide 9)

```@docs
design_w_torsion
```

`design_w_torsion(s, mat, Tu, Vu, Mu, L; load_type)` — full torsion design check per DG9. Returns torsional stresses and interaction check.

```@docs
torsional_stresses_ksi
```

Computes normal and shear stresses from pure torsion, warping torsion, and bending using DG9 Eqs. 4.1, 4.2a, 4.3a.

```@docs
check_torsion_yielding
```

`check_torsion_yielding(σ_b, σ_w, τ_b, τ_t, τ_ws, Fy; φ=0.90)` — von Mises interaction per DG9 §4.7.1.

### Slenderness Classification (Table B4.1)

`get_slenderness` dispatches on `ISymmSection` for W-shape slenderness classification. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_slenderness(s::ISymmSection, mat)` — classifies flange and web as compact, noncompact, or slender for flexure per Table B4.1b. Returns slenderness ratios and limit values:
- Flange (Case 10): `λp = 0.38√(E/Fy)`, `λr = 1.0√(E/Fy)`
- Web (Case 15): `λp = 3.76√(E/Fy)`, `λr = 5.70√(E/Fy)`

`get_compression_factors(s, mat)` — computes the Q factor (Qs × Qa) for compression per Table B4.1a / §E7.

```@docs
is_compact
```

`is_compact(s, mat)` — returns `true` if both flange and web are compact for flexure.

### P-M Interaction (AISC §H1)

See [AISC — Generic](generic.md) for `check_PM_interaction` and `check_PMxMy_interaction`, which apply to all section types including W shapes.

## Implementation Details

### Flexure Algorithm

The flexure calculation first checks LTB against `Lp` and `Lr` (F2-5, F2-6), then checks FLB against Table B4.1b limits. The governing `Mn` is the minimum of all applicable limit states, capped by `Mp`.

For the elastic LTB critical stress (F2-4), the constant `c = 1.0` for doubly-symmetric I-shapes. The `rts` parameter is precomputed and stored on the section, following AISC Commentary Eq. C-F2-15.

### Compression Algorithm

Compression considers both flexural buckling (E3) about the weak axis (governing for most W shapes) and flexural-torsional buckling (E4). For sections with slender elements, the Q-factor approach (E7) reduces the effective area. The implementation uses iterative convergence for Qa when web effective width depends on Fcr.

### Torsion

W shapes are open sections with low torsional rigidity. The implementation follows DG9 Case 1 (distributed torque) and Case 3 (concentrated torque), computing warping and St. Venant torsional stresses at critical locations along the member length. The normalized warping function `Wno` and warping statical moment `Sw1` are computed from DG9 Appendix C equations.

## Options & Configuration

The `AISCChecker` constructor accepts all fields as keyword arguments:

```julia
checker = AISCChecker(ϕ_b=0.9, ϕ_c=0.9, ϕ_v=1.0, deflection_limit=360.0, max_depth=24.0)
```

Set `deflection_limit` to `nothing` to skip deflection checks. The `prefer_penalty` multiplies the objective coefficient for non-preferred sections (> 1.0 penalizes them in optimization).

## Chapter I — Composite Members (Beams)

Composite slab-on-beam design with full and partial composite action per Chapter I.

```julia
using StructuralSizer

section = W("W21X55")
material = A992_Steel

# Define slab (solid slab, 7.5 in. thick, 4 ksi concrete)
slab = SolidSlabOnBeam(
    7.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3", 29000.0u"ksi",
    10.0u"ft", 10.0u"ft"  # beam spacing left/right
)

# Headed stud anchor (¾ in. × 5 in., Fu = 65 ksi)
anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi", 7850.0u"kg/m^3")

# Effective width (I3.1a)
b_eff = get_b_eff(slab, 45.0u"ft")

# Stud strength (I8.2a)
Qn = get_Qn(anchor, slab)

# Composite moment capacity (I3.2a, plastic stress distribution)
ΣQn = 40 * Qn   # 40 studs per half-span
result = get_ϕMn_composite(section, material, slab, b_eff, ΣQn)
# result.ϕMn, result.Mn, result.y_pna, result.Cf, result.a

# Partial composite: find minimum ΣQn for a target moment
req = find_required_ΣQn(section, material, slab, b_eff, 500.0u"kip*ft", Qn)
# req.ΣQn, req.n_studs_half, req.sufficient

# Negative moment (I3.2b) with slab rebar
Mn_neg = get_Mn_negative(section, material, 2.0u"inch^2", 60.0u"ksi")

# Deflection check (shored vs unshored)
defl = check_composite_deflection(section, material, slab, b_eff, ΣQn,
    45.0u"ft", 0.5u"kip/ft", 0.8u"kip/ft"; shored=false)
# defl.δ_DL, defl.δ_LL, defl.ok_LL

# Construction-stage check (bare steel, I3.1b)
const_check = check_construction(section, material, 200.0u"kip*ft", 50.0u"kip";
    Lb_const=45.0u"ft")
# const_check.flexure_ok, const_check.shear_ok
```

**Key types:**
- `SolidSlabOnBeam` / `DeckSlabOnBeam`: slab-on-beam configurations (solid concrete and metal deck)
- `HeadedStudAnchor`: stud properties, including `n_per_row` for multi-row layouts
- `CompositeContext`: bundles slab + anchor + geometry for the checker pipeline

**Equations:**
- Effective width: I3.1a (L/8, spacing/2, edge distance)
- Qn: I8.2a (Eq. I8-1), with Rg/Rp per User Note table
- Cf: I3.2d (min of concrete, steel, studs — Eqs. I3-1a/b/c)
- Mn: plastic stress distribution (I3.2a(a)), continuous PNA solver
- Negative Mn: I3.2b with Asr × Fysr
- I\_transformed / I\_LB: Commentary I3.2, AISC Manual Eq. C-I3-1 (Y2 method)

## Limitations & Future Work

### Not Implemented

| Feature | AISC Reference | Notes |
|:--------|:---------------|:------|
| Sway Frame Amplification (B2) | Appendix 8 | B2 functions exist but are not integrated into `AISCChecker`. Apply externally for sway frames. |
| Connection Design | Chapter J | No bolt/weld capacity, block shear, prying action, or connection detailing. |
| Web Crippling / Local Bearing | J10 | Concentrated load checks at supports not implemented. |
| Built-up Sections | E6 | Modified slenderness for built-up columns not implemented. |
| Single-Angle Members | Chapter E, F | Special provisions for single angles not implemented. |
| Asymmetric I-Shapes | — | Only doubly-symmetric W/S shapes; no channels, WT, or singly-symmetric I. |
| Composite Columns | I2 | Composite beams (I3) are implemented; composite columns are not. |
| Formed Metal Deck (parallel wr/hr < 1.5) | I3.2c | `DeckSlabOnBeam` is fully implemented for perpendicular deck and parallel deck with wr/hr ≥ 1.5. Parallel deck with wr/hr < 1.5 uses conservative Rg=0.85 but may need additional rib-level checks. |
| Elastic Stress Distribution | I3.2a(b) | Only plastic distribution implemented. Raises error when h/tw > 3.76√(E/Fy). |
| Seismic Provisions | AISC 341 | No seismic compactness, expected strengths, or special detailing. |
| Fire Design | Appendix 4 | No elevated temperature capacity reduction. |
| Fatigue | Appendix 3 | No fatigue/cyclic loading checks. |
| Web LB under Flexure (F4/F5) | F4, F5 | Noncompact/slender web flexure not implemented for the general case. |

### Simplifying Assumptions

| Assumption | Impact | Mitigation |
|:-----------|:-------|:-----------|
| Ae = 0.75·Ag for tension rupture | Conservative for most connections | Override with `Ae_ratio` parameter |
| Cb = 1.0 default | Conservative for moment gradient | Provide actual Cb from analysis |
| K = 1.0 default | Conservative for braced; unconservative for sway | Provide actual K from alignment charts |
| Shear Lv = L default | Conservative for distributed loads | Provide Lv for accuracy |
| Deflection uses linear scaling | Approximate for moment-controlled beams | Acceptable for typical cases |
| No stiffener design | Affects shear/bearing capacity | Use rolled shapes within web limits |

### Section Type Limitations

| Section | Supported | Not Supported |
|:--------|:----------|:--------------|
| W-shapes | Compression, flexure, shear, tension, torsion (DG9) | HSS preferred when torsion dominates |
| HSS Rect | All including torsion | — |
| HSS Round | All including torsion | — |
| Channels, WT, Angles | — | Not yet implemented |
| Plate girders | Web slenderness only | No tension field action (G3) |

## API Summary

### Capacity Functions (W Shapes)

| Function | Chapter | Description |
|:---------|:--------|:------------|
| `get_Pn`, `get_ϕPn` | E | Compression capacity |
| `get_Mn`, `get_ϕMn` | F | Flexural capacity |
| `get_Vn`, `get_ϕVn` | G | Shear capacity |
| `get_ϕPn_tension` | D | Tension capacity |
| `get_slenderness` | Table B4.1b | Flange/web classification |
| `get_compression_factors` | E7, Table B4.1a | Q factor for slender elements |
| `is_compact` | Table B4.1b | Compact check (flange + web) |
| `design_w_torsion` | DG9 | Torsion design check |

### Composite Functions (Chapter I)

| Function | Reference | Description |
|:---------|:----------|:------------|
| `get_Mn_composite`, `get_ϕMn_composite` | I3.2a | Positive flexural strength |
| `get_Mn_negative` | I3.2b | Negative flexural strength |
| `get_Cf` | I3.2d | Horizontal shear (compression force) |
| `get_Qn` | I8.2a | Stud nominal shear strength |
| `get_b_eff` | I3.1a | Effective slab width |
| `get_I_transformed`, `get_I_LB` | Commentary I3.2 | Composite / lower-bound moment of inertia |
| `check_composite_deflection` | I3 | Shored / unshored deflection |
| `check_construction` | I3.1b | Construction-stage bare steel check |
| `find_required_ΣQn` | I3.2d | Partial composite solver (binary search) |
| `validate_stud_diameter` | I8.1 | Stud d\_sa ≤ 2.5tf check |
| `validate_stud_length` | I8.2 | Stud l\_sa ≥ 4d\_sa and cover check |
| `check_stud_spacing` | I8.2d | Min/max longitudinal spacing |
| `stud_mass` | — | Single stud mass (for ECC/weight objectives) |
| `composite_stud_contribution` | — | Total stud cost contribution to objective |
| `extract_parallel_Asr` | I3.2b | Extract parallel slab rebar for negative moment |
| `beam_direction_from_vectors` | — | Check if rebar is parallel to beam direction |

### Interaction & Amplification (All Section Types)

See [Generic Provisions](generic.md) for the full API. Key functions:

| Function | Reference | Description |
|:---------|:----------|:------------|
| `check_PM_interaction` | H1-1 | Uniaxial P-M check |
| `check_PMxMy_interaction` | H1-2 | Biaxial P-Mx-My check |
| `compute_B1` | A-8-3 | P-δ amplification factor |
| `compute_B2` | A-8-6 | P-Δ amplification factor |
| `amplify_moments` | A-8-1 | Mr = B1·Mnt + B2·Mlt |

### Checker Interface

| Function | Description |
|:---------|:------------|
| `AISCChecker(; ...)` | Create checker with options |
| `create_cache(checker, n)` | Create capacity cache |
| `precompute_capacities!(...)` | Precompute length-independent values |
| `is_feasible(...)` | Check section feasibility (includes B1 amplification) |

## References

- AISC 360-16: Specification for Structural Steel Buildings
- AISC Steel Construction Manual, 15th Edition
- AISC Design Examples, Version 15.0
- AISC Design Guide 9: Torsional Analysis of Structural Steel Members
