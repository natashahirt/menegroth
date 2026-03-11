# AISC 360-16: Generic Provisions

> ```julia
> using StructuralSizer
> ur = check_PMxMy_interaction(200u"kip", 100u"kip*ft", 50u"kip*ft",
>     500u"kip", 300u"kip*ft", 150u"kip*ft")
> B1 = compute_B1(200u"kip", 5000u"kip", 0.85)
> Mr = amplify_moments(100u"kip*ft", 20u"kip*ft", B1, 1.05)
> ```

## Overview

This module contains AISC 360-16 provisions that apply to **all section types**: tension capacity (Chapter D), P-M interaction checks (Chapter H), and moment amplification (Appendix 8 / Chapter C). These functions are section-type-agnostic and are used by all AISC checkers.

Source: `StructuralSizer/src/members/codes/aisc/generic/*.jl`

## Functions

### Tension (AISC §D2)

`get_Pn_tension(s, mat; Ae_ratio=0.75)` — nominal tensile strength, minimum of:
- **Yielding on gross section (D2-1):** `Pn = Fy × Ag`
- **Rupture on net section (D2-2):** `Pn = Fu × Ae` where `Ae = Ag × Ae_ratio`

The default `Ae_ratio = 0.75` is a conservative approximation; use the actual effective net area ratio when connection details are known.

`get_ϕPn_tension(s, mat; Ae_ratio=0.75)` — design tensile strength with `ϕ_t = 0.90` for yielding, `ϕ_t = 0.75` for rupture. Returns the governing (minimum) value.

### P-M Interaction (AISC §H1)

```@docs
check_PM_interaction
```

`check_PM_interaction(Pu, Mu, ϕPn, ϕMn)` — uniaxial P-M interaction check per H1-1:

- When `Pr/ϕPn ≥ 0.2`: `ur = Pr/ϕPn + (8/9)(Mr/ϕMn) ≤ 1.0` (H1-1a)
- When `Pr/ϕPn < 0.2`: `ur = Pr/(2ϕPn) + Mr/ϕMn ≤ 1.0` (H1-1b)

Returns the utilization ratio `ur`. A convenience overload accepts section, material, and length arguments and internally computes `ϕPn` and `ϕMn`.

```@docs
check_PMxMy_interaction
```

`check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)` — biaxial P-M interaction per H1-1a/b with both axes:

- When `Pr/ϕPn ≥ 0.2`: `ur = Pr/ϕPn + (8/9)(Mrx/ϕMnx + Mry/ϕMny)`
- When `Pr/ϕPn < 0.2`: `ur = Pr/(2ϕPn) + Mrx/ϕMnx + Mry/ϕMny`

A convenience overload accepts section, material, unbraced lengths for both axes, and member length.

### Moment Amplification (AISC Appendix 8)

```@docs
compute_Cm
```

`compute_Cm(M1, M2; transverse_loading=false)` — equivalent uniform moment factor per A-8-4:

`Cm = 0.6 - 0.4 (M1/M2)` clamped to [0.4, 1.0]

When `transverse_loading = true`, `Cm = 1.0` regardless of end moments.

```@docs
compute_Pe1
```

`compute_Pe1(E, I, Lc1)` — elastic critical buckling load for the member in the plane of bending (A-8-5):

`Pe1 = π²EI / Lc1²`

where `Lc1 = K₁L` is the effective length in the plane of bending.

```@docs
compute_B1
```

`compute_B1(Pr, Pe1, Cm; α=1.0)` — nonsway amplification factor (A-8-3):

`B1 = Cm / (1 - α Pr/Pe1) ≥ 1.0`

A convenience overload accepts `(Pr, E, I, L, M1, M2; K=1.0, α=1.0, transverse_loading=false)` and internally computes `Cm` and `Pe1`.

```@docs
compute_RM
```

`compute_RM(Pmf, Pstory)` — reduction factor for first-order drift (A-8-8):

`RM = 1 - 0.15 (Pmf/Pstory)`

where `Pmf` is the total vertical load in columns that are part of the moment frame.

```@docs
compute_Pe_story
```

`compute_Pe_story(H, L, ΔH, RM)` — story elastic critical buckling load (A-8-7):

`Pe_story = RM × H × L / ΔH`

where `H` is the total story shear, `L` is the story height, and `ΔH` is the first-order interstory drift.

```@docs
compute_B2
```

`compute_B2(Pstory, Pe_story; α=1.0)` — sway amplification factor (A-8-6):

`B2 = 1 / (1 - α Pstory/Pe_story) ≥ 1.0`

A convenience overload accepts `(Pstory, H, L, ΔH; Pmf=0.0, α=1.0)` and internally computes `RM` and `Pe_story`.

```@docs
amplify_moments
```

`amplify_moments(Mnt, Mlt, B1, B2)` — required flexural strength (A-8-1):

`Mr = B1 × Mnt + B2 × Mlt`

where `Mnt` is the nonsway moment and `Mlt` is the sway (lateral translation) moment.

```@docs
amplify_axial
```

`amplify_axial(Pnt, Plt, B2)` — required axial strength (A-8-2):

`Pr = Pnt + B2 × Plt`

## Implementation Details

### P-M Interaction Switch Point

The H1-1a/H1-1b equations create a continuous but non-smooth interaction surface with a kink at `Pr/Pc = 0.2`. This switch point was chosen by AISC to provide a better fit to test data for members with low axial load, where the linear interaction (H1-1a) would be too conservative.

The implementation computes both equations and selects based on the `Pr/Pc` ratio. For biaxial interaction, moments about both axes are added in the moment term, which is conservative for biaxial bending per AISC Commentary §H1.1.

### Moment Amplification Strategy

The moment amplification method (Appendix 8) is a simplified alternative to rigorous second-order analysis. It separates effects into:

1. **B1 (nonsway):** P-δ effect — amplification of moments between member ends due to member curvature under axial load.
2. **B2 (sway):** P-Δ effect — amplification of moments from lateral translation of story levels.

For braced frames, `B2 = 1.0` and only B1 applies. For moment frames, both B1 and B2 are computed. The α factor is 1.0 for LRFD.

### Cm Convention

The sign convention for `M1` and `M2` follows AISC: `M1` is the smaller end moment, `M2` is the larger. When the member is in single curvature (`M1/M2 > 0`), Cm is reduced below 1.0. For double curvature (`M1/M2 < 0`), Cm increases. The result is clamped to `Cm ≥ 0.4`.

## Options & Configuration

These functions are standalone and do not require a checker object. The LRFD factor `α = 1.0` is the default; set `α = 1.6` for ASD if needed.

## Limitations & Future Work

- Tension rupture uses a simplified `Ae_ratio` rather than computing actual effective net area from connection geometry.
- No direct support for combined torsion + axial + flexure interaction (§H3) in the generic module; this is handled in section-specific torsion modules.
- Story stability calculations (`Pe_story`, `B2`) assume a regular story geometry; irregular configurations may need manual adjustment.
