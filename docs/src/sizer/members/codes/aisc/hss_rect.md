# AISC 360-16: Rectangular HSS

> ```julia
> using StructuralSizer
> hss = HSS("HSS8X4X1/4")
> mat = A992_Steel  # Fy = 50 ksi (same as A500 Gr. C for rect HSS)
> ϕMn = get_ϕMn(hss, mat; Lb=10u"ft")
> ϕPn = get_ϕPn(hss, mat, 10u"ft")
> ```

## Overview

This module implements AISC 360-16 capacity checks for rectangular and square HSS sections. It covers flexure (§F7), compression (§E3/E7), shear (§G4), torsion (§H3), and combined loading interaction. HSS-specific provisions differ from W shapes primarily in slenderness classification and local buckling treatment.

Source: `StructuralSizer/src/members/codes/aisc/hss_rect/*.jl`

## Key Types

```@docs
AISCChecker
```

Rectangular HSS checks use the same `AISCChecker` type as W shapes — dispatching on `HSSRectSection` selects the HSS-specific capacity functions.

## Functions

### Flexure (AISC §F7)

```@docs
get_ϕMn
```

`get_ϕMn(s::HSSRectSection, mat; Lb, Cb=1.0, axis=:strong, ϕ=0.9)` — design flexural strength for rectangular HSS.

```@docs
get_Mn
```

`get_Mn(s::HSSRectSection, mat; Lb, Cb=1.0, axis=:strong)` — nominal flexural strength. Limit states:

1. **Yielding (F7-1):** ``M_p = F_y \times Z_x``
2. **Flange local buckling (F7-2, F7-3):** for noncompact flanges, linear interpolation between ``M_p`` and ``F_y S_e``; for slender flanges, ``S_e`` from effective width (F7-3, F7-4)
3. **Web local buckling (F7-5, F7-6):** analogous treatment for web slenderness

HSS sections are not susceptible to LTB (closed cross-section).

### Compression (AISC §E3, §E7)

```@docs
get_ϕPn
```

`get_ϕPn(s::HSSRectSection, mat, L; axis=:weak, ϕ=0.9)` — design compressive strength.

```@docs
get_Pn
```

`get_Pn(s::HSSRectSection, mat, L; axis=:weak)` — nominal compressive strength. Uses:
- Flexural buckling (E3) with `Fe = π²E/(KL/r)²`
- Local buckling interaction via effective area `Ae` (E7) when flange or web is slender

The effective area calculation uses AISC E7-3/E7-5 with c1 = 0.18, c2 = 1.31 per Table E7.1 for walls of rectangular HSS.

### Shear (AISC §G4)

```@docs
get_ϕVn
```

`get_ϕVn(s::HSSRectSection, mat; axis=:strong, ϕ=nothing)` — design shear strength.

```@docs
get_Vn
```

`get_Vn(s::HSSRectSection, mat; axis=:strong)` — nominal shear strength per G4-1:

```math
V_n = 0.6\,F_y\,A_w\,C_{v2}
```

where ``A_w = 2ht`` for strong-axis shear. The ``C_{v2}`` coefficient follows G2.2 with ``k_v = 5.0``:

```math
C_{v2} = \begin{cases} 1.0 & h/t \leq 1.10\sqrt{k_v E / F_y} \\ \dfrac{1.10\sqrt{k_v E / F_y}}{h/t} & 1.10\sqrt{k_v E / F_y} < h/t \leq 1.37\sqrt{k_v E / F_y} \\ \dfrac{1.51\,k_v\,E}{(h/t)^2\,F_y} & h/t > 1.37\sqrt{k_v E / F_y} \end{cases}
```

### Torsion (AISC §H3)

```@docs
get_ϕTn
```

`get_ϕTn(s::HSSRectSection, mat; ϕ=0.90)` — design torsional strength.

```@docs
get_Tn
```

`get_Tn(s::HSSRectSection, mat)` — nominal torsional strength per H3-1: `Tn = Fcr × C` where `C` is the torsional constant for rectangular HSS.

```@docs
torsional_constant_rect_hss
```

`torsional_constant_rect_hss(B, H, t)` — HSS torsional constant per H3 User Note.

```@docs
get_Fcr_torsion
```

`get_Fcr_torsion(s::HSSRectSection, mat)` — torsional critical stress. Three regimes based on the larger of `b/t` and `h/t`:

- Compact (`≤ 2.45√(E/Fy)`): `Fcr = 0.6 Fy` (H3-3)
- Noncompact: linear interpolation (H3-4)
- Slender (`> 3.07√(E/Fy)`): elastic buckling `Fcr = 0.6 E (2.45√(E/Fy))² / (b/t)²` (H3-5)

```@docs
check_combined_torsion_interaction
```

`check_combined_torsion_interaction(Pr, Mr, Vr, Tr, Pc, Mc, Vc, Tc)` — combined loading interaction per H3-6:

```math
\left(\frac{P_r}{P_c} + \frac{M_r}{M_c}\right)^2 + \left(\frac{V_r}{V_c} + \frac{T_r}{T_c}\right)^2 \leq 1.0
```

```@docs
can_neglect_torsion
```

`can_neglect_torsion(Tr, Tc)` — returns `true` when torsion demand is below the threshold per H3.2.

### Slenderness (Table B4.1)

```@docs
get_slenderness
```

`get_slenderness(s::HSSRectSection, mat)` — flexural slenderness classification per Table B4.1b:
- Flange: `λp = 1.12√(E/Fy)`, `λr = 1.40√(E/Fy)`
- Web: `λp = 2.42√(E/Fy)`, `λr = 3.10√(E/Fy)` (adjusted for plastic neutral axis location on HSS webs; see Commentary §F7)

`get_compression_limits(s, mat)` — compression slenderness limit per Table B4.1a: `λr = 1.40√(E/Fy)` for walls of rectangular HSS.

## Implementation Details

### Effective Width (Slender Elements)

For slender elements under compression or flexure, the effective width approach (E7-3, E7-5) reduces the element width to account for local buckling:

```math
b_e = b\left(1 - c_1\sqrt{\frac{F_{el}}{f}}\right)\sqrt{\frac{F_{el}}{f}}
```

where ``F_{el} = c_2\,k\,E / (b/t)^2`` with ``c_1 = 0.18``, ``c_2 = 1.31`` from Table E7.1 for HSS walls. For flexure, effective section modulus `Se` is computed from the reduced cross-section.

### Shear Area Convention

For strong-axis shear, `Aw = 2 h t` (both webs contribute). For weak-axis shear, `Aw = 2 b t` (both flanges contribute). This differs from the W-shape convention where only the web carries shear.

### No LTB for HSS

Rectangular HSS sections are closed sections and are not susceptible to lateral-torsional buckling. The flexure check only considers yielding, FLB, and WLB.

## Options & Configuration

Same `AISCChecker` configuration as W shapes. The checker automatically selects HSS-specific provisions when dispatching on `HSSRectSection`.

## Limitations & Future Work

- No design for connections (gusset plates, through-plates, etc.).
- Wall thickness is the design thickness `tdes` (0.93 × nominal for ERW), not nominal.
- No consideration of corners (corner radius effect on properties is neglected for standard HSS).
