# Concrete Sections

> ```julia
> using StructuralSizer
> col = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=9, n_bars=8, cover=1.5u"inch")
> beam = RCBeamSection(b=12u"inch", h=24u"inch", bar_size=8, n_bars=3, cover=1.5u"inch")
> println("ρg = $(col.ρg), Ag = $(col.Ag)")
> ```

## Overview

Concrete section types represent the geometry and reinforcement layout for reinforced concrete members. The module covers rectangular beams, T-beams, rectangular columns, circular columns, and the novel PixelFrame cross-section system. All types subtype `AbstractSection` and are defined in `StructuralSizer/src/members/sections/concrete/`.

Reinforcement is modeled through `RebarLocation` objects that carry bar positions and areas, enabling P-M interaction diagram generation with arbitrary bar layouts.

## Key Types

### RC Beam Section

```@docs
RCBeamSection
```

**`RCBeamSection{T<:Length, A<:Area}`** represents a singly or doubly reinforced rectangular concrete beam:

| Field | Description |
|:------|:------------|
| `b` | Beam width |
| `h` | Total depth |
| `d` | Effective depth (to centroid of tension steel) |
| `cover` | Clear cover |
| `As`, `n_bars`, `bar_size` | Tension reinforcement: area, count, bar designation |
| `As_prime`, `n_bars_prime`, `bar_size_prime` | Compression reinforcement (0 for singly reinforced) |
| `d_prime` | Depth to compression steel from extreme compression fiber |
| `stirrup_size` | Transverse reinforcement bar designation |

### RC T-Beam Section

```@docs
RCTBeamSection
```

**`RCTBeamSection{T<:Length, A<:Area}`** extends the rectangular beam model with a T-shaped cross-section for slab-beam systems:

| Field | Description |
|:------|:------------|
| `bw` | Web width |
| `h` | Total depth |
| `d` | Effective depth |
| `bf` | Effective flange width (from tributary/code rules) |
| `hf` | Flange (slab) thickness |
| `cover` | Clear cover |
| `As`, `n_bars`, `bar_size` | Tension reinforcement |
| `As_prime`, `n_bars_prime`, `bar_size_prime` | Compression reinforcement |
| `d_prime` | Depth to compression steel |
| `stirrup_size` | Transverse reinforcement bar designation |

### RC Column Section (Rectangular)

```@docs
RCColumnSection
```

**`RCColumnSection{T<:Length, A<:Area}`** represents a rectangular RC column with arbitrary bar layout:

| Field | Description |
|:------|:------------|
| `b`, `h` | Width and depth |
| `Ag` | Gross area |
| `bars` | `Vector{RebarLocation}` — positions and areas of all bars |
| `As_total` | Total steel area |
| `ρg` | Gross reinforcement ratio |
| `cover` | Clear cover to ties/spirals |
| `tie_type` | `:tied` or `:spiral` |

### RC Circular Section

```@docs
RCCircularSection
```

**`RCCircularSection{T<:Length, A<:Area}`** represents a circular RC column:

| Field | Description |
|:------|:------------|
| `D` | Diameter |
| `Ag` | Gross area (`πD²/4`) |
| `bars` | `Vector{RebarLocation}` — bars arranged around the circle |
| `As_total` | Total steel area |
| `ρg` | Gross reinforcement ratio |
| `cover` | Clear cover to spiral |
| `tie_type` | `:spiral` or `:tied` |

### PixelFrame Section

```@docs
PixelFrameSection
```

**`PixelFrameSection`** is a novel cross-section type that uses pixel-based material assignment for fiber-reinforced concrete members:

| Field | Description |
|:------|:------------|
| `λ` | Layup type: `:Y`, `:X2`, or `:X4` |
| `L_px` | Pixel arm length |
| `t` | Pixel wall thickness |
| `L_c` | Straight region length before arc |
| `material` | `FiberReinforcedConcrete` with `fc′`, `fR1`, `fR3`, fiber dosage |
| `A_s` | Post-tensioning tendon area |
| `f_pe` | Effective prestress |
| `d_ps` | Tendon eccentricity from centroid |
| `section` | `CompoundSection` — computed polygon geometry |

### Rebar Location

**`RebarLocation{T<:Length, A<:Area}`** specifies a single reinforcing bar's position within a column section:

| Field | Description |
|:------|:------------|
| `x` | Distance from left edge |
| `y` | Distance from bottom edge |
| `As` | Bar area |

## Functions

### Geometry Helpers

**`effective_depth(s; axis=:x)`**

`effective_depth(s::RCColumnSection; axis=:x)` returns the distance from the compression face to the centroid of the tension steel. For `:x` axis bending, tension steel is at the bottom; for `:y` axis, at the left edge. For `RCCircularSection`, it returns the maximum `y`-coordinate of any bar.

**`rho(s)`**

`rho(s)` returns the reinforcement ratio. For beams: `As / (b × d)`. For columns: the stored `ρg`.

**`gross_moment_of_inertia(s)`**

`gross_moment_of_inertia(s)` computes `Ig` of the gross concrete section. For rectangular beams: `bh³/12`. For T-beams: parallel axis theorem applied to flange and web components.

**`n_bars(s)`**

`n_bars(s)` returns the number of reinforcing bars (`length(s.bars)` for column sections).

**`get_bar_depths(s)`**

`get_bar_depths(s::RCCircularSection)` returns a sorted vector of bar depths from the extreme compression fiber, used in P-M diagram generation.

### Centroid (T-Beams)

**`gross_centroid_from_top(s)`**

`gross_centroid_from_top(s::RCTBeamSection)` computes the centroid of the gross T-section measured from the top fiber.

## Implementation Details

Column sections store a `Vector{RebarLocation}` rather than a simple bar count and size. This allows the P-M interaction diagram generator (ACI §22.4) to compute strain compatibility at each bar layer accurately. The constructor places bars symmetrically around the perimeter based on `n_bars`, `bar_size`, and `cover`, then stores the expanded bar vector.

For rectangular columns, bars are placed along the four faces with uniform spacing. For circular columns, bars are distributed evenly around a circle at radius `D/2 - cover - d_bar/2`.

The `PixelFrameSection` uses a `CompoundSection` (polygon-based) geometry model. The actual cross-section shape is generated from the layup type (`λ`), pixel dimensions, and wall thickness. Material properties are drawn from a `FiberReinforcedConcrete` type that carries both compressive strength and residual flexural strengths (`fR1`, `fR3`) for the fiber contribution.

All lengths and areas carry `Unitful` dimensions, with internal conversions to inches for consistency with US customary code provisions.

## Options & Configuration

Sections are typically constructed via keyword constructors:

```julia
RCColumnSection(b=16u"inch", h=16u"inch", bar_size=9, n_bars=8, cover=1.5u"inch")
RCBeamSection(b=12u"inch", h=24u"inch", bar_size=8, n_bars=3, cover=1.5u"inch")
```

For catalogs of standard sections used in optimization, see [Section Catalogs](catalogs.md).

## Limitations & Future Work

- Beam sections do not support multiple layers of tension reinforcement (only a single layer at depth `d`).
- T-beam flanges are assumed to be in compression; negative moment regions with tension in the flange are not directly modeled.
- Tie spacing is not stored on `RCColumnSection`; it is determined by ACI code rules during design.
- No prestressed concrete beam section type (post-tensioning is only modeled in `PixelFrameSection`).
