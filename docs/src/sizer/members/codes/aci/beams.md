# ACI 318: Beam Design

> ```julia
> using StructuralSizer
> result = design_beam_flexure(200u"kip*ft", 12u"inch", 20u"inch", 4000u"psi", 60000u"psi", 29000u"ksi")
> Vc = Vc_beam(12u"inch", 20u"inch", 4000u"psi")
> shear = design_beam_shear(50u"kip", 12u"inch", 20u"inch", 4000u"psi", 60000u"psi")
> ```

## Overview

This module implements ACI 318 design provisions for reinforced concrete beams, covering flexure (§9.5 / §22.2), shear (§22.5), torsion (§22.7), and serviceability (§24.2). It supports singly reinforced, doubly reinforced, and T-beam designs.

The flexure design determines the required reinforcement area for a given factored moment. The shear design provides concrete shear capacity and required transverse reinforcement. The torsion design checks threshold and cracking torsion and determines reinforcement. Serviceability checks compute deflections using effective moment of inertia methods.

Source: `StructuralSizer/src/members/codes/aci/beams/*.jl`

## Key Types

```@docs
ACIBeamChecker
```

`ACIBeamChecker <: AbstractCapacityChecker` carries design parameters:

| Field | Description |
|:------|:------------|
| `fy_ksi` | Rebar yield strength (ksi) |
| `fyt_ksi` | Transverse reinforcement yield strength (ksi) |
| `Es_ksi` | Steel elastic modulus (ksi) |
| `λ` | Lightweight concrete factor (1.0 for normal weight) |
| `max_depth` | Maximum beam depth constraint |
| `w_dead_kplf` | Dead load for deflection check (kip/ft) |
| `w_live_kplf` | Live load for deflection check (kip/ft) |
| `defl_support` | Support condition for deflection (`:simply_supported`, `:one_end_continuous`, `:both_ends_continuous`, `:cantilever`) |
| `defl_ξ` | Time-dependent factor for sustained load deflection |

```@docs
ACIBeamCapacityCache
```

`ACIBeamCapacityCache` stores precomputed capacities for each catalog section:

| Field | Description |
|:------|:------------|
| `φMn` | Design flexural strengths |
| `φVn_max` | Maximum design shear strengths |
| `εt` | Tensile strain at nominal strength |
| `obj_coeffs` | Optimization objective coefficients |

## Functions

### Flexure (ACI §9.5 / §22.2)

```@docs
stress_block_depth
```

`stress_block_depth(As, fc, fy, b)` — Whitney stress block depth per §22.2.2.4:

```math
a = \frac{A_s \, f_y}{0.85 \, f'_c \, b}
```

```@docs
neutral_axis_depth
```

`neutral_axis_depth(a, fc)` — neutral axis depth from stress block:

```math
c = \frac{a}{\beta_1}
```

where ``\beta_1`` is determined from ``f'_c`` per §22.2.2.4.3.

```@docs
design_beam_flexure
```

`design_beam_flexure(Mu, b, d, fc, fy, Es; ...)` — complete flexural design. Returns required `As` (and `As_prime` if doubly reinforced). The algorithm:

1. Compute required ``R_n = M_u / (\phi \, b \, d^2)``
2. Solve for reinforcement ratio ``\rho = \frac{0.85 f'_c}{f_y}\left(1 - \sqrt{1 - \frac{2 R_n}{0.85 f'_c}}\right)``
3. Check strain to ensure tension-controlled behavior (``\varepsilon_t \geq 0.005``)
4. If singly reinforced is insufficient, add compression steel

```@docs
design_tbeam_flexure
```

`design_tbeam_flexure(Mu, bw, d, bf, hf, fc, fy; ...)` — T-beam flexural design. Determines whether the neutral axis falls within the flange or extends into the web:
- If `a ≤ hf`: design as rectangular beam with width `bf`
- If `a > hf`: use T-beam equilibrium with flange and web components

```@docs
effective_flange_width
```

`effective_flange_width(; bw, hf, sw, ln, position=:interior)` — effective flange width per ACI §8.12.2 (now §6.3.2). For interior beams, the effective width is the minimum of:
- `sw` (center-to-center beam spacing)
- `bw + 16hf`
- `bw + ln/4` (span/4 on each side)

### Shear (ACI §22.5)

```@docs
Vc_beam
```

`Vc_beam(bw, d, fc; λ=1.0, Nu=nothing, Ag=nothing)` — concrete shear capacity per Eq. 11-3 (ACI 318-14) / §22.5.5:

```math
V_c = 2 \lambda \sqrt{f'_c} \, b_w \, d
```

When axial compression ``N_u`` is present, the modified formula applies.

```@docs
Vs_required
```

`Vs_required(Vu, Vc; φ=0.75)` — required steel shear contribution:

```math
V_s = \frac{V_u}{\phi} - V_c
```

```@docs
Vs_max_beam
```

`Vs_max_beam(bw, d, fc)` — maximum permitted ``V_s`` per §11.4.7.9:

```math
V_{s,\max} = 8 \sqrt{f'_c} \, b_w \, d
```

```@docs
design_stirrups
```

`design_stirrups(Vs, d, fyt; bar_size=3)` — determines stirrup spacing for the required ``V_s``:

```math
s = \frac{A_v \, f_{yt} \, d}{V_s}
```

Subject to ACI maximum spacing limits (``d/2`` or ``d/4`` when ``V_s > 4\sqrt{f'_c}\, b_w\, d``).

```@docs
design_beam_shear
```

`design_beam_shear(Vu, bw, d, fc, fyt; ...)` — complete shear design returning `Vc`, required `Vs`, stirrup size, and spacing.

### Torsion (ACI §22.7)

```@docs
threshold_torsion
```

`threshold_torsion(Acp, pcp, fc_psi; λ=1.0, φ=0.75)` — torsion below which effects can be neglected (§11.5.1):

```math
T_{u,\text{threshold}} = \phi \lambda \sqrt{f'_c} \frac{A_{cp}^2}{p_{cp}}
```

where ``A_{cp}`` = area enclosed by outside perimeter, ``p_{cp}`` = outside perimeter.

```@docs
cracking_torsion
```

`cracking_torsion(Acp, pcp, fc_psi; λ=1.0)` — cracking torsion (§11.5.2.4):

```math
T_{cr} = 4 \lambda \sqrt{f'_c} \frac{A_{cp}^2}{p_{cp}}
```

```@docs
torsion_transverse_reinforcement
```

`torsion_transverse_reinforcement(Tu, Ao, fyt; θ=45°, φ=0.75)` — required transverse reinforcement for torsion (§11.5.3.6):

```math
\frac{A_t}{s} = \frac{T_u}{2 \phi \, A_o \, f_{yt} \cot\theta}
```

```@docs
torsion_longitudinal_reinforcement
```

`torsion_longitudinal_reinforcement(At_s, ph, fyt, fy; θ=45°)` — required longitudinal reinforcement for torsion (§11.5.3.7):

```math
A_l = \frac{A_t}{s} \cdot p_h \cdot \frac{f_{yt}}{f_y} \cdot \cot^2\theta
```

```@docs
design_beam_torsion
```

`design_beam_torsion(Tu, Vu, bw, h, d, fc, fy, fyt; ...)` — complete torsion design including compatibility torsion redistribution.

### Serviceability (ACI §24.2)

```@docs
design_beam_deflection
```

`design_beam_deflection(b, h, d, As, fc, fy, Es, L, w_dead, w_live; ...)` — computes immediate and long-term deflections. Returns component deflections (dead, live, sustained) and checks against L/Δ limits.

```@docs
effective_moment_of_inertia
```

`effective_moment_of_inertia(Mcr, Ma, Ig, Icr)` — effective moment of inertia per Branson's equation (ACI 318-14 §24.2.3.5):

```math
I_e = \left(\frac{M_{cr}}{M_a}\right)^3 I_g + \left[1 - \left(\frac{M_{cr}}{M_a}\right)^3\right] I_{cr} \leq I_g
```

```@docs
effective_moment_of_inertia_bischoff
```

`effective_moment_of_inertia_bischoff(Mcr, Ma, Ig, Icr)` — Bischoff (2005) formulation, adopted in ACI 318-19 §24.2.3.5:

```math
I_e = \frac{I_{cr}}{1 - \left(1 - \frac{I_{cr}}{I_g}\right)\left(\frac{M_{cr}}{M_a}\right)^2} \leq I_g
```

The Bischoff equation provides better accuracy for lightly reinforced sections and FRP-reinforced members.

## Implementation Details

### Flexure Design Algorithm

The flexure design uses direct solution of the Whitney stress block equilibrium rather than iterative methods. For singly reinforced beams:

1. Compute `φRn = Mu / (b d²)`
2. Solve `ρ = (0.85 fc′/fy)(1 - √(1 - 2Rn/(0.85 fc′)))` from the quadratic
3. Check `εt ≥ 0.005` for tension-controlled behavior (φ = 0.9)
4. Check `ρ ≥ ρ_min = max(3√fc′/fy, 200/fy)` per §9.6.1

When the section cannot be tension-controlled as singly reinforced, the design adds compression steel (`As_prime`) to maintain ductility while increasing capacity.

### T-Beam Effective Width

The effective flange width calculation follows §6.3.2 (ACI 318-19) which unified the previous §8.12.2 provisions. For interior beams, three limits are checked. For edge beams, the overhang is limited to min(6hf, sw/2, ln/8).

### Deflection Methods

Two methods are available for `Ie`:
- **Branson** (default): traditional cubic interpolation, conservative for heavily reinforced sections
- **Bischoff**: more accurate for lightly reinforced sections, adopted in ACI 318-19

Long-term deflection multiplier:

```math
\lambda_\Delta = \frac{\xi}{1 + 50\rho'}
```

where ``\xi`` is the time-dependent factor (1.0 at 3 months, 2.0 at 5+ years).

## Options & Configuration

`ACIBeamChecker` is configured through its fields:

```julia
checker = ACIBeamChecker(
    fy_ksi = 60.0,
    fyt_ksi = 60.0,
    Es_ksi = 29000.0,
    λ = 1.0,
    max_depth = 36.0,
    w_dead_kplf = 1.0,
    w_live_kplf = 0.8,
    defl_support = :simply_supported,
    defl_ξ = 2.0
)
```

Torsion design supports a `torsion_mode` option for compatibility vs. equilibrium torsion treatment.

## Limitations & Future Work

- Only rectangular and T-beam cross-sections are supported; L-beams and spandrels are not modeled.
- Deep beam provisions (§9.9) are not implemented.
- Prestressed beam design is not included (only mild steel reinforcement).
- Skin reinforcement for deep beams (§9.7.2.3) is not checked.
- Two-way slab shear (punching) is handled in the slab module, not here.
