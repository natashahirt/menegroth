# Steel Sections

```@meta
CurrentModule = StructuralSizer
```

> ```julia
> using StructuralSizer
> w = W("W14X22")
> println("A = $(section_area(w)), Ix = $(Ix(w))")
> asap = to_asap_section(w, A992_Steel)
> ```

## Overview

Steel section types represent the cross-sectional geometry and computed properties for hot-rolled and hollow structural steel shapes. Every section subtypes `AbstractSection` and implements a common interface (`section_area`, `section_depth`, `section_width`, `Ix`, `Iy`, `Sx`, `Sy`), enabling generic code in capacity checkers and optimization routines.

Sections are defined in `StructuralSizer/src/members/sections/steel/`.

## Key Types

### Abstract Hierarchy
```@docs
AbstractSection
AbstractHollowSection
AbstractRectHollowSection
AbstractRoundHollowSection
```

### Catalog Constructors

The standard AISC catalogs are exposed via convenience constructors:

```@docs
W
HSS
PIPE
HSSRound
```

### Section Geometry Traits (for visualization / rendering)

Section *geometry traits* are separate from section constructors. They are returned by
`section_geometry(section)` and are used by downstream visualization and meshing code.

```@docs
AbstractSectionGeometry
SolidRect
SolidRound
HollowRect
HollowRound
IShape
TShape
```

### W Shapes (Doubly-Symmetric I-Sections)

```@docs
ISymmSection
```

**`ISymmSection <: AbstractSection`** is a mutable struct representing doubly-symmetric I-shapes. In practice, StructuralSizer’s built-in AISC catalog loader provides W-shapes, but the geometry model is generic.

Input geometry fields:

| Field | Description |
|:------|:------------|
| `d` | Total depth |
| `bf` | Flange width |
| `tw` | Web thickness |
| `tf` | Flange thickness |

Derived geometry (computed at construction):

| Field | Description |
|:------|:------------|
| `h` | Clear web height (`d - 2tf`) |
| `ho` | Distance between flange centroids (`d - tf`) |
| `λ_f` | Flange slenderness (`bf / 2tf`) |
| `λ_w` | Web slenderness (`h / tw`) |
| `Aw`, `Af` | Web area, flange area |

Section properties: `A`, `Ix`, `Iy`, `Iyc`, `J`, `Cw`, `Sx`, `Sy`, `Zx`, `Zy`, `rx`, `ry`, `rts`

Additional fields:
- `kdes` — distance from outer flange face to web toe of fillet
- `PA`, `PB` — contour perimeters for fire protection (3-sided beams, 4-sided columns; per AISC Design Guide 19)
- `is_preferred` — AISC preferred (bolded) section flag
- `material` — optional attached `Metal`

### Rectangular HSS

```@docs
HSSRectSection
```

**`HSSRectSection <: AbstractRectHollowSection`** represents rectangular or square HSS shapes. Input geometry:

| Field | Description |
|:------|:------------|
| `H` | Outside height (depth) |
| `B` | Outside width |
| `t` | Design wall thickness |

Derived geometry uses the AISC convention for clear dimensions (`h = H - 3t`, `b = B - 3t`). Slenderness ratios `λ_f` (b/t), `λ_w` (h/t), `H_t`, `B_t` are precomputed.

Section properties: `A`, `Ix`, `Iy`, `Sx`, `Sy`, `Zx`, `Zy`, `J`, `rx`, `ry`

### Round HSS

```@docs
HSSRoundSection
```

**`HSSRoundSection <: AbstractRoundHollowSection`** represents round HSS (pipe) shapes. All section properties are symmetric about every axis:

| Field | Description |
|:------|:------------|
| `OD` | Outside diameter |
| `t` | Design wall thickness |
| `ID` | Inside diameter (`OD - 2t`) |
| `Dm` | Mean diameter (`OD - t`) |
| `D_t` | Slenderness ratio (`OD/t`) |

Section properties: `A`, `I` (= Ix = Iy), `S` (= Sx = Sy), `Z` (= Zx = Zy), `J` (= 2I), `r` (= rx = ry)

### Pipe Section

**`PipeSection`** is a type alias for `HSSRoundSection`. The AISC database distinguishes Pipe shapes by name, but they use the same geometric model.

```@docs
PipeSection
```

### Rebar

**`Rebar{L, W, A} <: AbstractSection`** represents a standard deformed reinforcing bar per ASTM A615:

| Field | Description |
|:------|:------------|
| `size` | Bar designation (e.g. 4 for #4) |
| `material` | `Metal` with yield/ultimate strengths |
| `diameter` | Nominal bar diameter |
| `weight` | Linear weight (lb/ft) |
| `A` | Cross-sectional area |

```@docs
Rebar
RebarLocation
```

## Functions

### Common Section Interface

- `section_area(s)` — returns the cross-sectional area of the section.
- `section_depth(s)` — returns the total depth of the section.
- `section_width(s)` — returns the width (flange width for I-sections, outside width for HSS).
- `weight_per_length(s, mat)` — computes weight per unit length as `section_area(s) * mat.ρ`.

### Section Properties

- `Ix(s)` — strong-axis moment of inertia.
- `Iy(s)` — weak-axis moment of inertia.
- `Sx(s)` — strong-axis elastic section modulus.
- `Sy(s)` — weak-axis elastic section modulus.

```@docs
BendingAxis
StrongAxis
WeakAxis
Ix
Iy
Sx
Sy
```

For `HSSRoundSection`, `Ix` and `Iy` both return `s.I`; `Sx` and `Sy` both return `s.S`.

### FEM Conversion

**`to_asap_section(section, material)`**

`to_asap_section(section, material)` converts a StructuralSizer section to an `Asap.Section` for finite element analysis. The resulting object carries `A`, `Ix`, `Iy`, `J`, `E`, `G`, and `ρ`. Overloads exist for:

- `ISymmSection` (with or without explicit material)
- `HSSRectSection` (with or without explicit material)
- `HSSRoundSection` (with or without explicit material)
- Generic fallback for any `AbstractSection` with `:A`, `:Ix`, `:Iy`, `:J` fields

### Rebar Utilities

- `bar_diameter(bar_size)` — look up nominal diameter from the standard rebar table.
- `bar_area(bar_size)` — look up cross-sectional area from the standard rebar table.

`bar_diameter(bar_size)` and `bar_area(bar_size)` look up properties from the standard rebar table.

## Implementation Details

Most catalog-based steel section types are **mutable** to allow post-construction assignment of the `material` field and catalog loading. (Rebar is an immutable section type.) Derived properties (slenderness ratios, section moduli) are computed once at construction time and stored, not recomputed on access.

`ISymmSection` stores both elastic (`Sx`, `Sy`) and plastic (`Zx`, `Zy`) section moduli because AISC 360 requires both for different limit states (e.g. `Mp = Fy × Zx` for yielding vs. `0.7 Fy × Sx` for the LTB anchor point).

Fire protection perimeters `PA` (3-sided, beams) and `PB` (4-sided, columns) follow AISC Design Guide 19 conventions for W/D ratios used in UL fire rating equations.

The `to_asap_section` conversion extracts only the elastic properties needed for linear FEM (`E`, `G`, `A`, `Ix`, `Iy`, `J`). Plastic behavior is handled by the capacity checkers, not the FEM model.

## Options & Configuration

Sections are typically loaded from CSV catalogs (see [Section Catalogs](catalogs.md)) rather than constructed manually. When constructing directly, all input geometry fields must be provided with `Unitful` quantities.

The `material` field is `Union{Metal, Nothing}` — it can be `nothing` when sections are used in catalog-based optimization where the material is passed separately.

## Limitations & Future Work

- No built-up section type (e.g. plate girders with different flange sizes).
- `Cw` (warping constant) and `rts` are only defined for `ISymmSection`, not for channels or angles.
- `exposed_perimeter` for fire protection is currently only implemented for `ISymmSection`.
- No angle or channel section types.
