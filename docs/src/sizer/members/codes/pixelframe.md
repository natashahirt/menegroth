# PixelFrame Design

> ```julia
> using StructuralSizer
> sec = generate_pixelframe_catalog(fc_values=[40.0], A_s_values=[226.0], d_ps_values=[150.0])[1]
> Mu = pf_flexural_capacity(sec; E_s=200_000.0, f_py=1615.0)
> Pu = pf_axial_capacity(sec; E_s=200_000.0)
> carbon = pf_carbon_per_meter(sec)
> ```

## Overview

The PixelFrame module implements a novel structural system using pixel-based cross-sections with variable material assignment. PixelFrame members use fiber-reinforced concrete (FRC) with post-tensioning tendons, enabling optimized material distribution across the cross-section.

The module covers axial capacity, flexural capacity, deflection analysis (with multiple methods and cracking regimes), tendon deviation forces, embodied carbon estimation, and per-pixel material optimization.

Reference: Wongsittikan (2024) thesis and the original `Pixelframe.jl` package.

**Source:** `StructuralSizer/src/members/codes/pixelframe/*.jl`

## Key Types

### Design Types

```@docs
PixelFrameDesign
```

```@docs
TendonDeviationResult
```

`PixelFrameDesign` is a mutable struct representing a fully designed PixelFrame member:

| Field | Description |
|:------|:------------|
| `section` | The `PixelFrameSection` geometry and material |
| `pixel_length` | Length of each pixel along the member |
| `n_pixels` | Number of pixels along the span |
| `pixel_materials` | Per-pixel material assignments |
| `tendon_deviation` | Tendon deviation force result |

### Deflection Regime

```@docs
DeflectionRegime
```

`@enum DeflectionRegime` classifies the section behavior under load:

| Value | Description |
|:------|:------------|
| `UNCRACKED` | Section is fully uncracked |
| `CRACKED` | Section is cracked |
| `LINEAR_ELASTIC_UNCRACKED` | Linear elastic, no cracking |
| `LINEAR_ELASTIC_CRACKED` | Linear elastic after cracking |
| `NONLINEAR_CRACKED` | Nonlinear behavior post-cracking |

### Deflection Methods

```@docs
PFDeflectionMethod
PFSimplified
PFThirdPointLoad
PFSinglePointLoad
```

### Checker & Cache

```@docs
PixelFrameChecker
```

`PixelFrameChecker <: AbstractCapacityChecker` for optimization:

| Field | Description |
|:------|:------------|
| `E_s_MPa` | Tendon elastic modulus (MPa) |
| `f_py_MPa` | Tendon yield strength (MPa) |
| `γ_c` | Partial safety factor for concrete |
| `min_depth_mm` | Minimum section depth (mm) |
| `min_width_mm` | Minimum section width (mm) |

```@docs
PixelFrameCapacityCache
```

Stores precomputed capacities: `Pu`, `Mu`, `Vu`, `depth_mm`, `width_mm`, `obj_coeffs`.

### Section Geometry

Three layup types are supported, each dispatched via `make_pixelframe_section`:

| Layup | Arms | Spacing | Typical Use |
|:------|:-----|:--------|:------------|
| `:Y` | 3 | 120° | Beams |
| `:X2` | 2 | 180° | Slabs, thin members, columns |
| `:X4` | 4 | 90° | Columns, biaxial members |

Sections are represented as `Asap.CompoundSection` / `SolidSection` with accurate polygon geometry. Section properties (area, centroid, moment of inertia) are computed via `Asap.jl`.

### Material Model (FRC)

The `FiberReinforcedConcrete` type (in `materials/frc.jl`, `materials/types.jl`) stores `fR1`, `fR3`, dosage, and `fiber_ecc`. Regression functions `fc′_dosage2fR1` and `fc′_dosage2fR3` map compressive strength and fiber dosage to residual flexural strengths.

## Functions

### Axial Capacity

```@docs
pf_axial_capacity
```

`pf_axial_capacity(s::PixelFrameSection; E_s, ϕ_compression)` — axial capacity per ACI 318-19 §22.4, with 0.8 × \(P_o\) reduction factor (ACI 318-19 Table 22.4.2.1) and \(\phi = 0.65\) for compression-controlled members.

```math
P_o = 0.85\,f'_c\,A_g
```

### Flexural Capacity

```@docs
pf_flexural_capacity
```

`pf_flexural_capacity(s::PixelFrameSection; E_s, f_py, Ω, max_iter)` — flexural capacity per ACI 318-19 §22.4, using strain compatibility analysis with rectangular stress block and β₁. Polygon clipping (`Asap.sutherland_hodgman`) handles the non-rectangular compression zone. The tendon stress at ultimate (`fps`) is computed iteratively via strain compatibility, and the ϕ factor follows ACI 318-19 Table 21.2.2 (tension/compression/transition). FRC tensile contribution (from `fR1`, `fR3`) is included in the tension zone.

### Shear Capacity

Shear capacity follows the fib MC2010 §7.7-5 FRC shear model (in `codes/fib/frc_shear.jl`):
- Linear `fFtuk` model using fR1 and fR3
- Size-effect factor:

```math
k = \min\left(1 + \sqrt{200/d}, 2\right)
```

  (corrected from original thesis)
- `V_Rd,Fmin` floor value per fib MC2010

### Deflection

```@docs
pf_deflection
```

`pf_deflection(s, L, w_or_M; method, E_s, f_py, support)` — deflection calculation with multiple methods:

**Simplified** (`PFSimplified`, default):
- Cracking moment `Mcr` per ACI 318-19 §24.2.3.5, plus decompression moment `Mdec` for EPT beams
- Cracked moment of inertia `Icr` via `Asap.depth_from_area` + `OffsetSection`
- Effective moment of inertia \(I_e\) using modified Branson's equation for EPT (Ng & Tan 2006):

```math
I_e = k^3 I_g + (1 - k^3) I_{cr}
```

  where

```math
k = (M_{cr} - M_{dec})/(M_a - M_{dec})
```

- Immediate deflection:

```math
\Delta = \frac{5 w L^4}{384\,E_c\,I_e}
```

- Serviceability check against ACI 318-19 Table 24.2.2 limits

**Full Ng & Tan** (`PFThirdPointLoad`, `PFSinglePointLoad`):
Full iterative model from Ng & Tan (2006) Part I with four deflection regimes:
- `LINEAR_ELASTIC_UNCRACKED`: \(M_a \le M_{cr}\) — iterate on fps only
- `LINEAR_ELASTIC_CRACKED`: \(M_{cr} < M_a \le M_{ecl}\) — nested fps + Icr loops
- `NONLINEAR_CRACKED`: \(M_{ecl} < M_a \le M_y\) — same nested loops
- Beyond `My` → returns `Inf` (failure)

Includes cracked bond reduction factor Ωc (4-branch formula), Hognestad parabola concrete strain, and second-order eccentricity/tendon depth updates. `pf_deflection_curve` generates moment–deflection curves for research validation.

### Embodied Carbon

```@docs
pf_carbon_per_meter
```

`pf_carbon_per_meter(s::PixelFrameSection)` — embodied carbon per meter of member length (kgCO₂/m). Sums the concrete, fiber, and tendon contributions based on pixel volumes and material ECC (embodied carbon coefficients).

```@docs
pf_concrete_ecc
```

`pf_concrete_ecc(fc′)` — returns the embodied carbon coefficient for concrete as a function of compressive strength. Higher-strength concretes have higher ECC due to increased cement content.

### Per-Pixel Design

```@docs
pixel_volumes
```

`pixel_volumes(design::PixelFrameDesign)` — computes the volume of concrete in each pixel, used for carbon and cost calculations.

```@docs
assign_pixel_materials
```

`assign_pixel_materials(governing, n_pixels, pixel_demands, material_pool, checker; symmetric)` — assigns materials to individual pixels based on local demands via post-MIP carbon-sorted relaxation. The MIP guarantees global optimality for the governing section; per-pixel assignment is a fast post-step. The `symmetric` flag enforces material symmetry about midspan by pairing symmetric pixel positions with the stronger material.

Additional per-pixel functions:
- `validate_pixel_divisibility` — errors if span is not a multiple of pixel length (default 500 mm)
- `pixel_carbon` — total embodied carbon summing per-pixel contributions
- `build_pixel_design` — convenience combining validation + assignment

### Catalog & Optimization

`generate_pixelframe_catalog` performs a Cartesian sweep of `L_px × t × L_c × λ × f'c × dosage × A_s × f_pe × d_ps` to build a section catalog. `PixelFrameChecker` implements `AbstractCapacityChecker` with cached capacities for MIP optimization. Beam and column options (`PixelFrameBeamOptions`, `PixelFrameColumnOptions`) support `MinCarbon` / `MinWeight` / `MinCost` objectives and minimum bounding-box constraints (`min_depth_mm`, `min_width_mm`) for punching shear compatibility.

### Tendon Deviation Axial Force

```@docs
pf_tendon_deviation_force
```

`pf_tendon_deviation_force(design, V_max; d_ps_support, f_ps, μ_s)` computes the additional clamping force needed at deviator points for friction-based shear transfer between pixels:
- Tendon angle θ from eccentricity change over pixel length
- Horizontal PT component:

```math
P_{\text{horizontal}} = A_{ps}\, f_{ps}\, \cos(\theta)
```

- Friction-required normal force:

```math
N_{\text{friction}} = V_{\max}/\mu_s
```

  (default \(\mu_s = 0.3\))
- Additional force:

```math
N_{\text{add}} = N_{\text{friction}} - P_{\text{horizontal}}
```

  (negative = PT alone suffices)

Stored in `PixelFrameDesign.tendon_deviation`. Reference: Wongsittikan (2024), `designPixelframe.jl` lines 474–536.

## Implementation Details

### Flexural Capacity Algorithm

The flexural capacity calculation uses an iterative strain compatibility approach:

1. Assume a neutral axis depth `c`
2. Compute concrete compressive force using Whitney stress block
3. Compute tendon stress from strain compatibility:

```math
f_{ps} = f_{pe} + \Delta f_{ps}
```

4. Add FRC tensile contribution from fibers in the tension zone:

```math
T_f = f_{Ftu}\,A_{f,\text{tension}}
```

5. Iterate on `c` until force equilibrium is achieved
6. Compute:

```math
M_n = \sum F \times \text{arm}
```

The FRC tensile strength in the tension zone uses:

```math
f_{Ftu} = f_{R3}/3
```

from the fib Model Code 2010.

### Deflection Regimes

The deflection calculation transitions between regimes based on the applied moment relative to cracking moment:

- \(M_a < M_{cr}\): uncracked (\(I_e = I_g\))
- `Ma ≥ Mcr`: cracked, using Bischoff-type effective moment of inertia
- For high loads: nonlinear cracked behavior with reduced stiffness

### Carbon Optimization

The per-pixel material assignment enables embodied carbon optimization by using only as much material strength as each pixel needs. Interior pixels under low stress can use lower-strength (lower-carbon) concrete, while critical pixels use higher-strength mixes. This is a form of functionally graded material (FGM) design.

## Options & Configuration

```julia
checker = PixelFrameChecker(
    E_s_MPa = 200_000.0,
    f_py_MPa = 1615.0,
    γ_c = 1.5,
    min_depth_mm = 200.0,
    min_width_mm = 200.0
)
```

PixelFrame sections use SI units (mm, MPa) throughout, unlike the US-customary units in the AISC and ACI modules.

## Intentional Differences from Original Pixelframe.jl

| Item | Original | This Implementation | Reason |
|:-----|:---------|:--------------------|:-------|
| Shear \(k\) factor | ``\min(\sqrt{200/d}, 2)`` (typo from thesis) | ``\min(1 + \sqrt{200/d}, 2)`` | Correct per fib MC2010 §7.7-5 |
| `V_Rd,Fmin` floor | Not implemented | Implemented | Enhancement per fib MC2010 |
| Unit handling | Bare `Float64` in mm/N/MPa | `Unitful.jl` quantities | Catches dimension errors at compile time |
| Geometry engine | Custom polygon math | `Asap.jl` `CompoundSection` | Reuses validated structural analysis library |
| Quadratic solver | `PolynomialRoots.roots` | Analytical quadratic formula | No extra dependency; exact same result |
| Per-pixel assignment | Greedy search (midspan out) | Post-MIP carbon-sorted relaxation | MIP guarantees global optimality for governing section |

## Limitations & Future Work

- Only `:Y`, `:X2`, and `:X4` layup types are implemented; other topologies are under development.
- Long-term creep and shrinkage effects on FRC are not modeled.
- Fire resistance of PixelFrame sections is not addressed.
- Connection design (pixel-to-pixel, member-to-member) is not included.
- Fatigue under cyclic loading is not considered.
- The carbon optimization uses a greedy per-pixel assignment; a global optimization (e.g., MIP over pixel materials) could yield better results.
