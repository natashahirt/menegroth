# AISC 360-16: Generic Provisions

> ```julia
> using StructuralSizer
> using Unitful
> ur = check_PMxMy_interaction(200u"kip", 100u"kip*ft", 50u"kip*ft",
>     500u"kip", 300u"kip*ft", 150u"kip*ft")
> B1 = compute_B1(200u"kip", 5000u"kip", 0.85)
> Mr = amplify_moments(100u"kip*ft", 20u"kip*ft", B1, 1.05)
> ```

## Overview

This module contains AISC 360-16 provisions that apply to **all section types**: tension capacity (Chapter D), P-M interaction checks (Chapter H), and moment amplification (Appendix 8 / Chapter C). These functions are section-type-agnostic and are used by all AISC checkers.

Source: `StructuralSizer/src/members/codes/aisc/generic/*.jl`

## Key Types

```@docs
AISCCapacityCache
B2StoryProperties
```

## Functions

### Tension (AISC §D2)

`StructuralSizer.get_Pn_tension(s, mat; Ae_ratio=0.75)` — nominal tensile strength, minimum of:
- **Yielding on gross section (D2-1):** ``P_n = F_y\,A_g``
- **Rupture on net section (D2-2):** ``P_n = F_u\,A_e`` where ``A_e = A_g\,A_{e,\text{ratio}}``

The default `Ae_ratio = 0.75` is a conservative approximation; use the actual effective net area ratio when connection details are known.

`StructuralSizer.get_ϕPn_tension(s, mat; Ae_ratio=0.75)` — design tensile strength with ``\phi_t = 0.90`` for yielding and ``\phi_t = 0.75`` for rupture. Returns the governing (minimum) value.

### P-M Interaction (AISC §H1)

```@docs
check_PM_interaction
```

`check_PM_interaction(Pu, Mu, ϕPn, ϕMn)` — uniaxial P-M interaction check per H1-1:

```math
\text{H1-1a:}\quad \frac{P_r}{\phi P_n} + \frac{8}{9}\frac{M_r}{\phi M_n} \leq 1.0 \qquad \left(\frac{P_r}{\phi P_n} \geq 0.2\right)
```

```math
\text{H1-1b:}\quad \frac{P_r}{2\,\phi P_n} + \frac{M_r}{\phi M_n} \leq 1.0 \qquad \left(\frac{P_r}{\phi P_n} < 0.2\right)
```

Returns the utilization ratio. A convenience overload accepts section, material, and length arguments and internally computes ``\phi P_n`` and ``\phi M_n``.

```@docs
check_PMxMy_interaction
```

`check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)` — biaxial P-M interaction per H1-1a/b with both axes:

- When ``P_r/(\phi P_n) \ge 0.2``:

```math
u_r = \frac{P_r}{\phi P_n} + \frac{8}{9}\left(\frac{M_{rx}}{\phi M_{nx}} + \frac{M_{ry}}{\phi M_{ny}}\right)
```

- When ``P_r/(\phi P_n) < 0.2``:

```math
u_r = \frac{P_r}{2\,\phi P_n} + \frac{M_{rx}}{\phi M_{nx}} + \frac{M_{ry}}{\phi M_{ny}}
```

A convenience overload accepts section, material, unbraced lengths for both axes, and member length.

### Moment Amplification (AISC Appendix 8)

```@docs
compute_Cm
```

`compute_Cm(M1, M2; transverse_loading=false)` — equivalent uniform moment factor per A-8-4:

```math
C_m = 0.6 - 0.4\,(M_1/M_2)
```

with the §App.8.2.1.2 sign convention (``M_1/M_2 > 0`` for reverse
curvature, ``M_1/M_2 < 0`` for single curvature). AISC 360-16 places no
upper or lower bound on ``C_m``; reverse-curvature configurations
correctly produce ``C_m < 0.4``, which physically reduces the
destabilizing P-δ amplification.

When `transverse_loading = true`, ``C_m = 1.0`` regardless of end moments.

```@docs
compute_Pe1
```

`compute_Pe1(E, I, Lc1)` — elastic critical buckling load for the member in the plane of bending (A-8-5):

```math
P_{e1} = \frac{\pi^2 E I}{L_{c1}^2}
```

where ``L_{c1} = K_1 L`` is the effective length in the plane of bending.

```@docs
compute_B1
```

`compute_B1(Pr, Pe1, Cm; α=1.0)` — nonsway amplification factor (A-8-3):

```math
B_1 = \frac{C_m}{1 - \alpha\,P_r / P_{e1}} \geq 1.0
```

A convenience overload accepts `(Pr, E, I, L, M1, M2; K=1.0, α=1.0, transverse_loading=false)` and internally computes `Cm` and `Pe1`.

```@docs
compute_RM
```

`compute_RM(Pmf, Pstory)` — reduction factor for first-order drift (A-8-8):

```math
R_M = 1 - 0.15\,(P_{mf}/P_{story})
```

where `Pmf` is the total vertical load in columns that are part of the moment frame.

```@docs
compute_Pe_story
```

`compute_Pe_story(H, L, ΔH, RM)` — story elastic critical buckling load (A-8-7):

```math
P_{e,\text{story}} = R_M\,H\,L/\Delta_H
```

where `H` is the total story shear, `L` is the story height, and `ΔH` is the first-order interstory drift.

```@docs
compute_B2
```

`compute_B2(Pstory, Pe_story; α=1.0)` — sway amplification factor (A-8-6):

```math
B_2 = \frac{1}{1 - \alpha\,P_{\text{story}} / P_{e,\text{story}}} \geq 1.0
```

A convenience overload accepts `(Pstory, H, L, ΔH; Pmf=0.0, α=1.0)` and internally computes `RM` and `Pe_story`.

```@docs
amplify_moments
```

`amplify_moments(Mnt, Mlt, B1, B2)` — required flexural strength (A-8-1):

```math
M_r = B_1 M_{nt} + B_2 M_{lt}
```

where ``M_{nt}`` is the nonsway moment and ``M_{lt}`` is the sway (lateral translation) moment.

```@docs
amplify_axial
```

`amplify_axial(Pnt, Plt, B2)` — required axial strength (A-8-2):

```math
P_r = P_{nt} + B_2 P_{lt}
```

## Implementation Details

### P-M Interaction Switch Point

The H1-1a/H1-1b equations create a continuous but non-smooth interaction surface with a kink at \(P_r/(\phi P_n) = 0.2\). This switch point was chosen by AISC to provide a better fit to test data for members with low axial load, where the linear interaction (H1-1a) would be too conservative.

The implementation computes both equations and selects based on the `Pr/ϕPn` ratio. For biaxial interaction, moments about both axes are added in the moment term, which is conservative for biaxial bending per AISC Commentary §H1.1.

### Moment Amplification Strategy

The moment amplification method (Appendix 8) is a simplified alternative to rigorous second-order analysis. It separates effects into:

1. **B1 (nonsway):** P-δ effect — amplification of moments between member ends due to member curvature under axial load.
2. **B2 (sway):** P-Δ effect — amplification of moments from lateral translation of story levels.

For braced frames, `B2 = 1.0` and only B1 applies. For moment frames, both B1 and B2 are computed. The α factor is 1.0 for LRFD.

### Cm Convention

The sign convention for `M1` and `M2` follows AISC Appendix 8: `M1` is the smaller end moment and `M2` is the larger, with `M1` **signed** to indicate curvature. **Reverse curvature (double curvature)** corresponds to `M1/M2 > 0`; **single curvature** corresponds to `M1/M2 < 0`. The result is clamped to `Cm ≥ 0.4`.

## Options & Configuration

These functions are standalone and do not require a checker object. The LRFD factor `α = 1.0` is the default; set `α = 1.6` for ASD if needed.

## Limitations & Future Work

- Tension rupture uses a simplified `Ae_ratio` rather than computing actual effective net area from connection geometry.
- No direct support for combined torsion + axial + flexure interaction (§H3) in the generic module; this is handled in section-specific torsion modules.
- Story stability calculations (`Pe_story`, `B2`) assume a regular story geometry; irregular configurations may need manual adjustment.
