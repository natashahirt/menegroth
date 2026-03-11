# AISC 360-16: Round HSS

> ```julia
> using StructuralSizer
> hss = get_hss_round_section("HSS6.000X0.250")
> mat = A500GrC()
> ϕMn = get_ϕMn(hss, mat; Lb=8u"ft")
> ϕVn = get_ϕVn(hss, mat)
> ```

## Overview

This module implements AISC 360-16 capacity checks for round HSS and Pipe sections. Round sections have symmetric properties about all axes, simplifying many calculations. The module covers flexure (§F8), compression (§E3/E7), shear (§G5/G6), torsion (§H3), and slenderness classification.

Source: `StructuralSizer/src/members/codes/aisc/hss_round/*.jl`

## Key Types

Round HSS checks use the same `AISCChecker` type as other steel sections — dispatching on `HSSRoundSection` selects the round-specific capacity functions. `PipeSection` is a type alias for `HSSRoundSection` and uses the same code paths.

## Functions

### Flexure (AISC §F8)

`get_ϕMn` and `get_Mn` dispatch on `HSSRoundSection` for round-specific flexure. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕMn(s::HSSRoundSection, mat; Lb, Cb=1.0, axis=:strong, ϕ=0.9)` — design flexural strength.

`get_Mn(s::HSSRoundSection, mat; Lb, Cb=1.0, axis=:strong)` — nominal flexural strength. Limit states:

1. **Yielding (F8-1):** `Mp = Fy × Z`
2. **Local buckling (F8-2):** for noncompact sections (`0.07 E/Fy < D/t ≤ 0.31 E/Fy`):
   `Mn = (0.021 E/(D/t) + Fy) × S`
3. **Local buckling (F8-3):** for slender sections (`D/t > 0.31 E/Fy`):
   `Mn = 0.33 E / (D/t) × S`

Round HSS are not susceptible to LTB (closed circular cross-section).

### Compression (AISC §E3, §E7)

`get_ϕPn` and `get_Pn` dispatch on `HSSRoundSection` for round-specific compression. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕPn(s::HSSRoundSection, mat, L; axis=:weak, ϕ=0.9)` — design compressive strength.

`get_Pn(s::HSSRoundSection, mat, L; axis=:weak)` — nominal compressive strength. Uses:
- Flexural buckling (E3) — the axis argument is irrelevant since `rx = ry = r`
- Local buckling interaction for slender walls: effective area from E7-6/E7-7

When `D/t > 0.11 E/Fy`, the effective area is reduced:

`Ae = Ag (2/3 + 0.038 (E/Fy)/(D/t))`

### Shear (AISC §G5/G6)

`get_ϕVn` and `get_Vn` dispatch on `HSSRoundSection` for round-specific shear. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕVn(s::HSSRoundSection, mat; Lv=nothing, axis=:strong, ϕ=nothing)` — design shear strength.

`get_Vn(s::HSSRoundSection, mat; Lv=nothing, axis=:strong)` — nominal shear strength. The shear critical stress `Fcr` is the larger of (G5-2a) and (G5-2b):

- `Fcr_a = 1.60 E / (√(Lv/D) × (D/t)^(5/4))`
- `Fcr_b = 0.78 E / (D/t)^(3/2)`
- `Vn = Fcr × Ag / 2` (G5-1), capped at `0.6 Fy × Ag / 2`

### Torsion (AISC §H3)

`get_ϕTn` and `get_Tn` dispatch on `HSSRoundSection` for round-specific torsion. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_ϕTn(s::HSSRoundSection, mat; L=nothing, ϕ=0.90)` — design torsional strength.

`get_Tn(s::HSSRoundSection, mat; L=nothing)` — nominal torsional strength per H3-1: `Tn = Fcr × C` where `C = J / rm` for round sections.

```@docs
torsional_constant_round_hss
```

`torsional_constant_round_hss(D, t)` — torsional constant for round HSS (= 2I for thin-walled circular tubes).

`get_Fcr_torsion` dispatches on `HSSRoundSection` for the round-specific torsion critical stress. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_Fcr_torsion(s::HSSRoundSection, mat; L=nothing)` — torsional critical stress per H3-2a/H3-2b:

- `Fcr = max(1.23 E / (√(L/D) × (D/t)^(5/4)), 0.60 E / (D/t)^(3/2))`
- Capped at `0.6 Fy`

### Slenderness (Table B4.1)

`get_slenderness` dispatches on `HSSRoundSection` for round-specific slenderness classification. See [AISC — HSS Rect](hss_rect.md) for the generic `@docs` entry.

`get_slenderness(s::HSSRoundSection, mat)` — classifies the D/t ratio for flexure per Table B4.1b:
- Compact: `D/t ≤ 0.07 E/Fy`
- Noncompact: `0.07 E/Fy < D/t ≤ 0.31 E/Fy`
- Slender: `D/t > 0.31 E/Fy`

Compression slenderness limit per Table B4.1a: `D/t ≤ 0.11 E/Fy`.

## Implementation Details

### Axial Symmetry

Since round HSS have identical properties about all axes (`Ix = Iy = I`, `rx = ry = r`), the `axis` keyword argument in compression is effectively ignored — the same buckling load governs regardless of axis. The functions still accept the argument for interface compatibility.

### Shear Length Parameter

The shear equations (G5-2a) include a term `Lv/D` where `Lv` is the distance from maximum to zero shear. When `Lv` is not provided, a conservative default (large `Lv`) is used, which may slightly underestimate capacity.

### D/t Limits

AISC 360-16 §B4.1b(20) limits `D/t ≤ 0.45 E/Fy` for round HSS in compression. Sections exceeding this limit are not in the standard catalog but would be flagged during slenderness checks.

## Options & Configuration

Same `AISCChecker` configuration as other steel sections. No round-HSS-specific options beyond the standard resistance factors.

## Limitations & Future Work

- No consideration of end connections or cap plates on round HSS.
- Combined torsion + flexure + compression interaction for round HSS uses the same H3-6 equation as rectangular HSS.
- No provisions for concrete-filled round HSS (composite tubes).
