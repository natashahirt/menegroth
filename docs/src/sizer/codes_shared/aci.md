# ACI Shared Utilities

> ```julia
> using StructuralSizer
> β = beta1(4000.0u"psi")           # Whitney stress block factor
> Mcr = cracking_moment(fr(4000.0u"psi"), Ig, h)
> Ie = effective_moment_of_inertia(Mcr, Ma, Ig, Icr)  # Branson
> ```

## Overview

The shared ACI module provides common functions used across slabs, beams,
columns, and foundations.  These include the Whitney stress block, punching shear
geometry, deflection calculations, PCA stiffness tables for EFM, rebar
utilities, fire protection provisions, and material property functions.

All functions reference ACI 318-11 clause numbers and are unit-safe via
Unitful.jl.

**Source:** `StructuralSizer/src/codes/aci/`

## Key Types

No exported types are defined in this module; it provides pure functions.

## Functions

### Material Properties (ACI 318-11 §8.5, §9.5, §10.2)

```@docs
beta1
Ec
fr
```

### Whitney Stress Block (ACI 318-11 §10.2.7)

```@docs
required_reinforcement
```

### Punching Shear (ACI 318-11 §11.11, §22.6)

```@docs
punching_geometry
punching_perimeter
punching_capacity_stress
punching_capacity_interior
punching_demand
combined_punching_stress
check_punching_shear
check_combined_punching
gamma_f
gamma_v
polar_moment_Jc_interior
polar_moment_Jc_edge
punching_αs
punching_β
effective_slab_width
punching_check
one_way_shear_capacity
one_way_shear_demand
check_one_way_shear
```

### Deflection (ACI 318-11 §24.2)

```@docs
cracking_moment
cracked_moment_of_inertia
cracked_moment_of_inertia_tbeam
immediate_deflection
long_term_deflection_factor
deflection_limit
required_Ix_for_deflection
```

`effective_moment_of_inertia` and `effective_moment_of_inertia_bischoff` are documented on the [ACI Beams](../members/codes/aci/beams.md) page.

### Rebar Utilities (ACI 318-11 §7.6)

```@docs
bar_diameter
bar_area
infer_bar_size
select_bars
select_bars_for_size
select_bars_candidates
```

### PCA Tables (PCA Notes on ACI 318-11, Appendix 20A)

```@docs
pca_slab_beam_factors
pca_column_factors
pca_slab_beam_factors_np
pca_np_fem_coefficients
```

### Fire Protection (ACI/TMS 216.1-14)

The concrete fire resistance functions (`min_thickness_fire`, `min_cover_fire_slab`, `min_cover_fire_beam`, `min_dimension_fire_column`, `min_cover_fire_column`) are documented on the [Fire Protection](../materials/fire_protection.md) materials page.

## Implementation Details

### Whitney Stress Block (§10.2.7)

The factor ``\beta_1`` relates the depth of the equivalent rectangular stress
block ``a`` to the neutral axis depth ``c``:

| ``f'_c`` (psi) | ``\beta_1`` |
|:----------------|:------------|
| ≤ 4000 | 0.85 |
| 4000–8000 | ``0.85 - 0.05(f'_c - 4000)/1000`` |
| ≥ 8000 | 0.65 |

`required_reinforcement(Mu, b, d, fc, fy)` solves the Whitney equation for
tension steel area ``A_s``.  The solution is ``A_s = (0.85 f'_c b / f_y)(d - \sqrt{d^2 - 2M_u / (0.85 \phi f'_c b)})``
per ACI §21.2.2 (tension-controlled, ``\phi = 0.90``).

### Punching Shear (§11.11, §22.6)

Critical section geometry functions handle three column positions:

- **Interior**: 4-sided perimeter at ``d/2`` from all column faces
- **Edge**: 3-sided, with the slab edge closing one side
- **Corner**: 2-sided, two free edges

The nominal shear stress (§11.11.2.1) is the minimum of three expressions
(Eqs. 11-31, 11-32, 11-33), governing by column aspect ratio ``\beta``,
perimeter-to-depth ratio ``b_0/d``, and the location factor ``\alpha_s``.

The polar moment ``J_c`` (R11.11.7.2) is computed analytically for rectangular
critical sections, accounting for the centroid offset ``c_{AB}`` for edge and
corner columns.

### Effective Moment of Inertia (§24.2)

Two formulations are provided:

**Branson** (ACI Eq. 9-10):
```math
I_e = \left(\frac{M_{cr}}{M_a}\right)^3 I_g + \left[1 - \left(\frac{M_{cr}}{M_a}\right)^3\right] I_{cr}
```

**Bischoff** (2005):
```math
I_e = \frac{I_{cr}}{1 - \left(\frac{M_{cr}}{M_a}\right)^2 \left(1 - \frac{I_{cr}}{I_g}\right)}
```

Bischoff is preferred for lightly reinforced sections where Branson
overestimates ``I_e``.  Both formulations handle the uncracked case
(``M_a < M_{cr}``) by returning ``I_g``.

T-beam cracked sections (`cracked_moment_of_inertia_tbeam`) account for the
effective flange width and compression in the flange.

### PCA Tables

Stiffness factors for the Equivalent Frame Method are interpolated from the PCA
Notes on ACI 318-11, Appendix 20A:

- **Table A1**: Slab-beam stiffness ``(k, \text{COF}, m)`` as a function of
  ``c_1/l_1`` and ``c_2/l_2``
- **Table A7**: Column stiffness ``(k, \text{COF})`` as a function of
  ``t_a/t_b`` and ``H/H_c``
- **Non-prismatic**: `pca_slab_beam_factors_np` handles drop panels with
  variable section depth

Bilinear interpolation is used between tabulated values.

### Fire Protection (ACI/TMS 216.1-14)

Fire protection tables provide:
- Minimum slab thickness (Table 4.2) by fire rating and aggregate type
- Minimum cover for slabs (Table 4.3.1.1), beams (Table 4.3.1.2), and
  columns (§4.5.3)
- Minimum column dimension (Table 4.5.1a)

Aggregate types: `:siliceous` (conservative), `:carbonate`, `:sand_lightweight`,
`:lightweight`.

## Limitations & Future Work

- PCA table interpolation uses linear extrapolation outside tabulated ranges;
  extreme ``c/l`` ratios may produce inaccurate stiffness factors.
- The rebar selection algorithm (`select_bars`) tries sizes #3 through #11 and
  selects the combination with the least total area that satisfies both
  ``A_{s,\text{reqd}}`` and maximum spacing.  It does not optimize for cost or
  constructability.
- Fire protection is limited to ACI 216.1-14; Eurocode fire design is not
  implemented.
- `required_Ix_for_deflection` is a steel-beam utility included here for
  convenience; it should eventually move to the AISC shared module.
