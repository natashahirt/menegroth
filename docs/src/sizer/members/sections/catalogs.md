# Section Catalogs

> ```julia
> using StructuralSizer
> w_sections = preferred_W()
> hss = all_HSS()
> rc_cols = square_rc_columns()
> println("$(length(w_sections)) preferred W shapes, $(length(hss)) HSS, $(length(rc_cols)) RC columns")
> ```

## Overview

Section catalogs provide databases of standard structural sections for use in discrete optimization. Steel catalogs are loaded from CSV files mirroring the AISC Steel Construction Manual tables. Concrete catalogs are generated programmatically from standard dimension and reinforcement grids. PixelFrame catalogs are generated from parametric sweeps.

All catalogs are **lazy-loaded** — data is read from disk or generated on first access, then cached in module-level dictionaries for subsequent calls.

## Key Types

Catalogs return vectors of section types described in the section-specific pages:
- `ISymmSection` for W shapes
- `HSSRectSection` for rectangular HSS
- `HSSRoundSection` for round HSS / Pipe
- `RCColumnSection` for RC columns
- `RCBeamSection` for RC beams
- `RCTBeamSection` for RC T-beams
- `PixelFrameSection` for PixelFrame members

## Functions

### AISC Steel Catalogs

Source: `StructuralSizer/src/members/sections/steel/catalogs/aisc_w.jl`, `aisc_hss.jl`

#### W Shapes

`all_W()` — Returns a vector of all available `ISymmSection` W-shapes from the AISC catalog.

```@docs
preferred_W
```

Returns only the AISC preferred (bolded) W shapes — the subset recommended for economy and availability.

`W_names()` — Returns a vector of all W-shape designation strings (e.g. `"W14X22"`) as a `Vector{String}`.

#### Rectangular HSS

`all_HSS()` — Returns all available `HSSRectSection` sections from the AISC catalog.

`HSS_names()` — Returns HSS rectangular section designation strings as a `Vector{String}`.

#### Round HSS

`all_HSSRound()` — Returns all available `HSSRoundSection` sections from the AISC catalog.

`HSSRound_names()` — Returns round HSS designation strings as a `Vector{String}`.

#### Pipe

- `all_PIPE()` — alias for `all_HSSRound()`. Pipe shapes use the same `HSSRoundSection` type.
- `PIPE_names()` — alias for `HSSRound_names()`.

### RC Concrete Catalogs

Source: `StructuralSizer/src/members/sections/concrete/catalogs/`

```@docs
standard_rc_columns
```

Generates a catalog of RC column sections by sweeping over sizes, bar sizes, and bar counts:

```julia
standard_rc_columns(;
    sizes = 8:2:36,           # column dimension in inches
    bar_sizes = [6,7,8,9,10,11],
    n_bars_range = 4:4:16,
    cover = 1.5u"inch",
    include_rectangular = true,
    aspect_ratios = [1.5, 2.0]
)
```

```@docs
square_rc_columns
```

Convenience wrapper that calls `standard_rc_columns` with `include_rectangular=false` for square columns only.

```@docs
standard_rc_beams
```

Generates a catalog of RC beam sections:

```julia
standard_rc_beams(;
    widths = [10,12,14,16,18,20,24],
    depths = [12,14,16,18,20,22,24,28,30,36],
    bar_sizes = [5,6,7,8,9,10],
    n_bars_range = 2:6,
    cover = 1.5u"inch",
    stirrup_size = 3
)
```

```@docs
standard_rc_tbeams
```

Generates a catalog of RC T-beam sections. Requires `flange_width` and `flange_thickness` as keyword arguments (these depend on the slab geometry):

```julia
standard_rc_tbeams(;
    flange_width,              # effective flange width (from code)
    flange_thickness,          # slab thickness
    web_widths = [10,12,14,16,18,20,24],
    depths = [16,18,20,22,24,28,30,36],
    bar_sizes = [5,6,7,8,9,10],
    n_bars_range = 2:6,
    cover = 1.5u"inch",
    stirrup_size = 3
)
```

### PixelFrame Catalog

Source: `StructuralSizer/src/members/sections/concrete/catalogs/pixelframe_catalog.jl`

```@docs
generate_pixelframe_catalog
```

Generates a parametric catalog of PixelFrame sections by sweeping over geometry, material, and tendon parameters:

```julia
generate_pixelframe_catalog(;
    λ_values = [:Y],
    L_px_values = [125.0],       # mm
    t_values = [30.0],           # mm
    L_c_values = [30.0],         # mm
    fc_values = 28:100,          # MPa
    dosage_values = [20.0],      # kg/m³ fiber dosage
    fR1_values = nothing,        # MPa (auto from dosage if nothing)
    fR3_values = nothing,        # MPa (auto from dosage if nothing)
    A_s_values = [157.0, 226.0, 402.0],  # mm² tendon area
    f_pe_values = [500.0],       # MPa effective prestress
    d_ps_values = 50:25:250,     # mm tendon eccentricity
    E_s = 200_000.0,             # MPa
    f_py = 0.85 * 1900.0,       # MPa tendon yield
    fiber_ecc = 1.4              # ECC for fiber dosage → fR mapping
)
```

## Implementation Details

### Steel Catalog Loading

Steel catalogs are loaded from CSV files stored in `StructuralSizer/data/`. The CSV files mirror AISC Manual Table 1-1 (W shapes), Table 1-11/1-12 (HSS), and Table 1-13/1-14 (Pipe). On first call, the CSV is parsed, `ISymmSection` / `HSSRectSection` / `HSSRoundSection` objects are constructed, and they are stored in module-level `Dict{String, Section}` caches.

The `is_preferred` flag on steel sections corresponds to bolded entries in the AISC Manual — these are the sections most commonly stocked by mills and service centers.

### RC Catalog Generation

RC catalogs are generated combinatorially. For columns, every combination of `(size, bar_size, n_bars)` produces one `RCColumnSection`, with bars placed symmetrically. Sections that violate ACI 318 detailing rules (minimum bar spacing, `ρg` range 1%–8%) are filtered out during generation.

For beams, every `(width, depth, bar_size, n_bars)` combination is generated, with sections violating minimum width or spacing rules removed.

### Caching Strategy

All catalog functions check a module-level cache (e.g. `W_CATALOG`, `HSS_RECT_CATALOG`) and only load/generate data if the cache is empty. This ensures the (sometimes slow) CSV parsing or combinatorial generation happens only once per Julia session.

## Options & Configuration

Steel catalogs are fixed by the AISC database. To filter by depth, weight, or other criteria, use standard Julia filtering:

```julia
light_w = filter(s -> section_area(s) < 20u"inch^2", all_W())
```

RC catalogs accept keyword arguments to control the sweep ranges.

### Multi-Material Catalogs

For optimization over multiple concrete grades or steel grades, use `expand_catalog_with_materials`:

```julia
expanded, sec_idx, mat_idx = expand_catalog_with_materials(catalog, [NWC_4000, NWC_5000])
```

This creates a Cartesian product of sections × materials for the MIP optimizer.

## Limitations & Future Work

- No metric steel catalogs (e.g. European HE/IPE shapes).
- Steel catalogs are US-only (AISC).
- RC catalog generation can be slow for large sweep ranges; consider narrowing ranges for interactive use.
- No built-up or custom section catalogs.
- Glulam catalogs are not yet implemented.
