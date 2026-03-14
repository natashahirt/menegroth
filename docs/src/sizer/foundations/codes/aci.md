# ACI Foundation Design

> ```julia
> using StructuralSizer
> using Unitful
> demand = FoundationDemand(1;
>     Pu=400.0kip, Ps=300.0kip, Mux=80.0kip * u"ft",
>     c1=20u"inch", c2=20u"inch", shape=:rectangular,
> )
> opts   = SpreadFootingOptions(material=RC_4000_60)
> result = design_footing(SpreadFooting(), demand, medium_sand; opts=opts)
> uconvert(u"ft", result.B)
> result.utilization
> ```

## Overview

The ACI foundation module implements spread footing, strip footing, and mat
foundation design per ACI 318-11 and ACI 336.2R-88.  Each design function
follows a multi-step workflow covering bearing, punching shear, one-way shear,
flexure, development length, and bearing/dowel checks.

**Source:** `StructuralSizer/src/foundations/codes/aci/`

## Key Types

See [Foundation Types & Options](../types.md) for `SpreadFooting`, `StripFooting`,
and `MatFoundation` type documentation.

```@docs
SpreadFootingResult
StripFootingResult
MatFootingResult
RigidMat
ShuklaAFM
WinklerFEA
```

## Functions

### Spread Footing

```@docs
design_footing
```

### Strip Footing

The `design_footing(::StripFooting, ...)` function accepts a vector of demands
and column positions along the strip.

### Mat Foundation

The `design_footing(::MatFoundation, ...)` function dispatches to one of three
analysis methods based on `MatFootingOptions.analysis_method`:

```@docs
recommend_foundation_strategy
```

## Implementation Details

### Spread Footing Design (ACI 318-11)

The `design_footing(::SpreadFooting, ...)` workflow:

1. **Bearing sizing** (square footing, service load):

```math
B = \sqrt{\frac{P_s}{q_a}}
```

2. **Punching shear** (ACI §8.4.4.2): punching check uses `punching_check(...)` with full biaxial unbalanced-moment transfer (`Mux`, `Muy`) and the critical section at \(d/2\).
3. **One-way shear** (ACI §22.5): checks one-way shear in both directions at a section located \(d\) from the column face.
4. **Flexure**: designs cantilever reinforcement at the column face using an iterative lever arm \(jd\) calculation and enforces ACI minimum temperature/shrinkage reinforcement (ACI §7.6.1.1).
5. **Development length** (ACI §25.4.2): checks simplified tension development length against the available footing projection.
6. **Bearing check** (ACI §22.8): evaluates column-to-footing bearing with the ACI area-ratio enhancement and reports dowel demand when bearing in the column concrete controls.

Minimum steel per ACI §7.6.1.1 is computed from the bar grade, using \(\rho_{\min}=0.0018\) for Grade 60 and reducing for higher grades (capped at 0.0014).

### Strip Footing Design (ACI 318-11)

The strip footing design treats the footing as a rigid beam:

1. **Plan sizing**: Width from ``P_s / (q_a \cdot L)``; length from column
   spacing plus overhangs
2. **Shear and moment diagrams**: `_strip_VM_diagram` computes V(x) and M(x)
   along the strip using equilibrium with uniform soil pressure and concentrated
   column loads
3. **Punching shear**: At each column per ACI §8.4.4.2
4. **One-way shear**: At ``d`` from each column face
5. **Longitudinal steel**: From maximum positive and negative moments
6. **Transverse steel**: Short-direction bending between columns
7. **Development and bearing**: Per ACI §25.4.2 and §22.8

### Mat Foundation Design

Three analysis methods are available, selected via `MatFootingOptions.analysis_method`:

#### RigidMat (ACI 336.2R §4.2)

Assumes uniform soil pressure.  Strip moments are computed from the Kramrisch
method: continuous beam on elastic supports with tributary widths.

#### ShuklaAFM — Shukla Approximate Flexible Method (ACI 336.2R §6.1.2)

Shukla's (1984) closed-form solution for a plate on elastic foundation:

1. Compute relative stiffness: \(\lambda_c = \left(\frac{k_s}{4 E_c I}\right)^{1/4}\)
2. Evaluate Kelvin–Bessel functions ``Z_3, Z_4`` for moment and shear at
   each column location
3. Superpose contributions from all columns
4. Envelope with rigid mat moments (Steps 3–4 of ACI 336.2R §6.1.2)

The subgrade modulus ``k_s`` is scaled per ACI 336.2R §3.3.2 Eq. 3-8 for the
mat width.

#### WinklerFEA (ACI 336.2R §6.4, §6.7, §6.9)

Finite element plate model on Winkler springs:

1. Generate plate mesh (triangular shell elements)
2. Assign Winkler springs at nodes: \(k_{\text{node}} = k_s \, A_{\text{trib}}\)
3. Double edge spring stiffness per ACI 336.2R §6.9
4. Apply concentrated column loads at nearest nodes
5. Solve for displacements, moments, and shears
6. Extract strip moments for reinforcement design

### Common Mat Utilities

- `_mat_plan_sizing`: Computes plan dimensions with overhang from the outermost
  columns, checks minimum overhang per ACI 318 §22.6
- `_mat_punching_util`: Punching utilization at each column
- `_unique_spans`: Sorted unique span lengths for strip-moment computation

## Options & Configuration

### SpreadFootingOptions

| Field | Default | Description |
|:------|:--------|:------------|
| `material` | `RC_4000_60` | Concrete + rebar material bundle |
| `cover` | 3 in. | Clear cover to reinforcement |
| `bar_size` | 8 | Rebar bar size (#8, etc.) |
| `pier_shape` | `:rectangular` | Legacy field (ignored for ACI spread footings); use `FoundationDemand.shape` |
| `pier_c1` | 18 in. | Legacy field (ignored for ACI spread footings); use `FoundationDemand.c1` |
| `pier_c2` | 18 in. | Legacy field (ignored for ACI spread footings); use `FoundationDemand.c2` |
| `ϕ_flexure` | 0.90 | ACI 318-11 §9.3.2 strength reduction |
| `ϕ_shear` | 0.75 | ACI 318-11 §9.3.2 strength reduction |
| `ϕ_bearing` | 0.65 | Bearing strength reduction factor |

### MatFootingOptions

| Field | Default | Description |
|:------|:--------|:------------|
| `analysis_method` | `RigidMat()` | Analysis method selector (`RigidMat`, `ShuklaAFM`, `WinklerFEA`) |
| `cover` | 3 in. | Clear cover |
| `bar_size_x` | 8 | Rebar bar size in x |
| `bar_size_y` | 8 | Rebar bar size in y |
| `min_depth` | 24 in. | Minimum mat thickness |
| `edge_overhang` | `nothing` | Edge overhang (auto if `nothing`) |

## Limitations & Future Work

- Spread footing preliminary sizing assumes uniform soil pressure (no pressure redistribution for eccentricity). Biaxial moments (`Mux`, `Muy`) are currently used in the punching shear transfer check, not to modify bearing pressure distribution.
- WinklerFEA uses uniform ``k_s``; depth-dependent or nonlinear subgrade
  reaction models are not supported.
- Pile cap design (deep foundations) is not implemented.
- Combined footings under biaxial loading are not supported.
- Soil improvement (grouting, stone columns) effects on bearing capacity are
  not modeled.
