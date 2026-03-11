# ACI Foundation Design

> ```julia
> using StructuralSizer
> demand = FoundationDemand(1; Pu=400u"kip", Mux=80u"kip*ft", c1=20u"inch", c2=20u"inch")
> result = design_footing(SpreadFooting(), demand, medium_sand)
> result.B               # footing width
> result.utilization     # governing check ratio
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
SpreadFootingOptions
StripFootingOptions
MatFootingOptions
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
analysis methods based on `MatFootingOptions.method`:

```@docs
recommend_foundation_strategy
```

## Implementation Details

### Spread Footing Design (ACI 318-11)

The `design_footing(::SpreadFooting, ...)` workflow:

1. **Bearing sizing**: ``B = \sqrt{P_s / q_a}`` (square), adjusted for eccentricity
   from ``M_{ux}, M_{uy}``
2. **Punching shear** (ACI §8.4.4.2): Critical section at ``d/2`` from column face;
   capacity per ACI §11.11.2.1 (three-equation minimum)
3. **One-way shear** (ACI §22.5): Critical section at ``d`` from column face;
   ``V_c = 2\lambda\sqrt{f'_c}\,b_w\,d``
4. **Flexure**: Cantilever moment at column face; Whitney stress block for
   required steel area, with iterative ``jd`` convergence
5. **Development length** (ACI §25.4.2): Check bar embedment within available
   footing projection
6. **Bearing check** (ACI §22.8): Column-to-footing bearing stress with area
   ratio enhancement; dowel bars if needed

Minimum steel per ACI §7.6.1.1: ``A_{s,\min} = 0.0018\,b\,h``.

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

Three analysis methods are available, selected via `MatFootingOptions.method`:

#### RigidMat (ACI 336.2R §4.2)

Assumes uniform soil pressure.  Strip moments are computed from the Kramrisch
method: continuous beam on elastic supports with tributary widths.

#### ShuklaAFM — Shukla Approximate Flexible Method (ACI 336.2R §6.1.2)

Shukla's (1984) closed-form solution for a plate on elastic foundation:

1. Compute relative stiffness: ``\lambda_c = \left(\frac{k_s}{4 E_c I}\right)^{1/4}``
2. Evaluate Kelvin–Bessel functions ``Z_3, Z_4`` for moment and shear at
   each column location
3. Superpose contributions from all columns
4. Envelope with rigid mat moments (Steps 3–4 of ACI 336.2R §6.1.2)

The subgrade modulus ``k_s`` is scaled per ACI 336.2R §3.3.2 Eq. 3-8 for the
mat width.

#### WinklerFEA (ACI 336.2R §6.4, §6.7, §6.9)

Finite element plate model on Winkler springs:

1. Generate plate mesh (quad shell elements)
2. Assign Winkler springs at nodes: ``k_{\text{node}} = k_s \times A_{\text{trib}}``
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
| `cover` | 3 in. | Clear cover to reinforcement |
| `bar_size` | 5 | Rebar bar size (#4, #5, etc.) |
| `pier_shape` | `:square` | Column shape (`:square`, `:round`) |
| `ϕ_flexure` | 0.90 | ACI §9.3.2 strength reduction |
| `ϕ_shear` | 0.75 | ACI §9.3.2 strength reduction |

### MatFootingOptions

| Field | Default | Description |
|:------|:--------|:------------|
| `method` | `RigidMat()` | Analysis method |
| `cover` | 3 in. | Clear cover |
| `bar_size` | 6 | Rebar bar size |
| `overhang_ratio` | 0.15 | Min overhang as fraction of span |
| `h_min` | 24 in. | Minimum mat thickness |

## Limitations & Future Work

- Eccentricity from biaxial moments uses the kern limit approximation; full
  soil pressure redistribution for large eccentricities is not implemented.
- WinklerFEA uses uniform ``k_s``; depth-dependent or nonlinear subgrade
  reaction models are not supported.
- Pile cap design (deep foundations) is not implemented.
- Combined footings under biaxial loading are not supported.
- Soil improvement (grouting, stone columns) effects on bearing capacity are
  not modeled.
