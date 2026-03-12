# Timber Sections

> ```julia
> using StructuralSizer
> glulam = GlulamSection(5.125u"inch", 12.0u"inch"; stress_class="24F-V4")
> println("A = $(glulam.A), Ix = $(glulam.Ix)")
> ```

## Overview

Timber sections represent cross-sectional geometry for engineered wood members. Currently only glued-laminated timber (glulam) sections are implemented, providing basic geometric properties for use with the NDS capacity checker.

Source: `StructuralSizer/src/members/sections/timber/glulam_section.jl`

## Key Types

```@docs
GlulamSection
```

**`GlulamSection <: AbstractSection`** represents a glulam beam or column section:

| Field | Description |
|:------|:------------|
| `name` | Optional section name |
| `b` | Width |
| `d` | Depth |
| `stress_class` | Glulam stress class (e.g. `"24F-V4"`) |
| `A` | Cross-sectional area (`b × d`) |
| `Ix` | Strong-axis moment of inertia (`bd³/12`) |
| `Iy` | Weak-axis moment of inertia (`db³/12`) |
| `Sx` | Strong-axis elastic section modulus (`bd²/6`) |
| `Sy` | Weak-axis elastic section modulus (`db²/6`) |

### Constants

**`STANDARD_GLULAM_WIDTHS`**

Standard glulam widths per industry practice: `[3.125, 5.125, 6.75, 8.75, 10.75]` inches.

**`GLULAM_LAM_THICKNESS`**

Standard lamination thickness: `1.5` inches (for Western species glulam).

## Functions

The `GlulamSection` convenience constructor computes all section properties from `b` and `d`:

```julia
GlulamSection(b, d; name=nothing, stress_class="24F-V4")
```

`section_area`, `section_depth`, and `section_width` are implemented for `GlulamSection`, following the standard `AbstractSection` interface.

## Implementation Details

Section properties are computed analytically for a solid rectangular cross-section:
- `A = b × d`
- `Ix = b × d³ / 12`, `Iy = d × b³ / 12`
- `Sx = b × d² / 6`, `Sy = d × b² / 6`

Depths should be multiples of the lamination thickness (`GLULAM_LAM_THICKNESS = 1.5"`) for realistic glulam members.

The `stress_class` field stores the design value identifier (e.g. `"24F-V4"` means Fb = 2400 psi, shear class V4) but stress class lookup tables are not yet implemented — allowable stresses are currently provided through material objects.

## Options & Configuration

- Widths should be selected from `STANDARD_GLULAM_WIDTHS` for standard availability.
- Depths should be integer multiples of `GLULAM_LAM_THICKNESS`.
- The `stress_class` defaults to `"24F-V4"`, a common balanced layup.

## Limitations & Future Work

- Only rectangular solid sections are supported. No tapered, curved, or notched members.
- No plastic section modulus (`Zx`, `Zy`) — timber design uses elastic properties.
- Stress class lookup (NDS Supplement Table 5A/5B) is not yet implemented; allowable stresses must be supplied via a material type.
- No sawn lumber section type.
- The NDS capacity checker is currently a stub.
