# ACI 318: Beam Design

> ```julia
> using StructuralSizer
> using Unitful
>
> mat = RC_4000_60
> Mu  = 200u"kip*ft"
> Vu  = 50u"kip"
>
> b = 12u"inch"
> h = 20u"inch"
> d = beam_effective_depth(h)  # defaults match ACI beam helpers (cover/stirrups/bar dia)
>
> flex  = design_beam_flexure(Mu, b, d, mat.concrete.fc′, mat.rebar.Fy, mat.rebar.E)
> Vc    = Vc_beam(b, d, mat.concrete.fc′)
> shear = design_beam_shear(Vu, b, d, mat.concrete.fc′, mat.transverse.Fy)
> ```

## Overview

This module implements ACI 318-11 design provisions for reinforced concrete beams, covering flexure (Chapter 10), shear (Chapter 11), torsion (§11.5), and serviceability (deflection per §9.5.2). It supports singly reinforced, doubly reinforced, and T-beam designs.

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

`stress_block_depth(As, fc, fy, b)` — Whitney stress block depth per ACI 318-11 §10.2.7:

```math
a = \frac{A_s \, f_y}{0.85 \, f'_c \, b}
```

```@docs
neutral_axis_depth
```

`neutral_axis_depth(a, fc)` — neutral axis depth per ACI 318-11 §10.2.7.3:

```math
c = \frac{a}{\beta_1}
```

where ``\beta_1`` is determined from ``f'_c`` per ACI 318-11 §10.2.7.3.

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

`effective_flange_width(; bw, hf, sw, ln, position=:interior)` — effective flange width per ACI 318-11 §8.12.2. The helper follows the ACI 318-11 overhang limits:
- **Interior**: each side overhang ≤ min(8hf, sw/2, ln/8)
- **Edge**: overhang ≤ min(6hf, sw/2, ln/12)

### Shear (ACI 318-11 §11.2, §11.4)

```@docs
Vc_beam
```

`Vc_beam(bw, d, fc; λ=1.0, Nu=nothing, Ag=nothing)` — concrete shear capacity per ACI 318-11 Eq. (11-3) / §11.2.1.1:

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

Subject to ACI 318-11 maximum spacing limits (§11.4.5): ``d/2`` or ``d/4`` when ``V_s > 4\sqrt{f'_c}\, b_w\, d``.

```@docs
design_beam_shear
```

`design_beam_shear(Vu, bw, d, fc, fyt; ...)` — complete shear design returning `Vc`, required `Vs`, stirrup size, and spacing.

### Torsion (ACI 318-11 §11.5)

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

### Serviceability (ACI 318-11 §9.5.2)

```@docs
design_beam_deflection
```

`design_beam_deflection(b, h, d, As, fc, fy, Es, L, w_dead, w_live; ...)` — computes immediate and long-term deflections. Returns component deflections (dead, live, sustained) and checks against L/Δ limits.

```@docs
effective_moment_of_inertia
```

`effective_moment_of_inertia(Mcr, Ma, Ig, Icr)` — effective moment of inertia per Branson's equation (ACI 318-11 Eq. (9-10)):

```math
I_e = \left(\frac{M_{cr}}{M_a}\right)^3 I_g + \left[1 - \left(\frac{M_{cr}}{M_a}\right)^3\right] I_{cr} \leq I_g
```

```@docs
effective_moment_of_inertia_bischoff
```

`effective_moment_of_inertia_bischoff(Mcr, Ma, Ig, Icr)` — Bischoff (2005) reciprocal interpolation:

```math
I_e = \frac{I_{cr}}{1 - \left(1 - \frac{I_{cr}}{I_g}\right)\left(\frac{M_{cr}}{M_a}\right)^2} \leq I_g
```

The Bischoff equation provides better accuracy for lightly reinforced sections and FRP-reinforced members.

## Implementation Details

### Flexure Design Algorithm

The flexure design uses direct solution of the Whitney stress block equilibrium rather than iterative methods. For singly reinforced beams:

1. Compute:

```math
\phi R_n = \frac{M_u}{b\,d^2}
```

2. Solve:

```math
\rho = \left(\frac{0.85 f'_c}{f_y}\right)\left(1 - \sqrt{1 - \frac{2 R_n}{0.85 f'_c}}\right)
```

3. Check tension-controlled behavior:

```math
\varepsilon_t \ge 0.005 \qquad (\phi = 0.9)
```

4. Check minimum reinforcement (ACI 318-11 §10.5.1):

```math
\rho \ge \rho_{\min} = \max\!\left(\frac{3\sqrt{f'_c}}{f_y}, \frac{200}{f_y}\right)
```

When the section cannot be tension-controlled as singly reinforced, the design adds compression steel (`As_prime`) to maintain ductility while increasing capacity.

### T-Beam Effective Width

The effective flange width helper follows the ACI 318-11 §8.12.2 overhang limits (interior: min(8hf, sw/2, ln/8); edge: min(6hf, sw/2, ln/12)).

### Deflection Methods

Two methods are available for `Ie`:
- **Branson** (default): traditional cubic interpolation, conservative for heavily reinforced sections
- **Bischoff**: more accurate for lightly reinforced sections and irregular members (reciprocal interpolation)

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
