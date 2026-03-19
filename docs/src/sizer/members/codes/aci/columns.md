# ACI 318: Column Design

> ```julia
> using StructuralSizer
> col = RCColumnSection(b=16u"inch", h=16u"inch", bar_size=9, n_bars=8, cover=1.5u"inch")
> mat = RC_4000_60
> diagram = generate_PM_diagram(col, mat)
> ur = utilization_ratio(diagram, 200.0, 100.0)  # Pu [kip], Mu [kip-ft]
> ```

## Overview

This module implements ACI 318-11 provisions for reinforced concrete column design, including P–M interaction diagrams, biaxial bending checks, and slenderness (moment magnification) effects. It supports both rectangular and circular column cross-sections.

The central data structure is the `PMInteractionDiagram`, which stores the full interaction surface from pure compression to pure tension. Capacity checks interpolate on this diagram to determine whether a given (Pu, Mu) pair is within the capacity envelope.

Source: `StructuralSizer/src/members/codes/aci/columns/*.jl`

### Design Philosophy

- **LRFD only** — Strength design with φ factors per §9.3.2
- **US units internally** — P–M helper functions use kip and kip-ft (bare `Real`); section geometry uses Unitful lengths and is converted internally to inches
- **Strain compatibility** — Full fiber analysis, not approximate methods
- **Catalog-based optimization** — Sections from predefined catalogs

### Units & Input Flexibility

The API accepts **any Unitful quantity** — conversions are automatic:

```julia
using StructuralSizer: kip  # Asap custom unit

# All equivalent — units converted internally to ACI (kip, kip·ft)
size_columns([2200u"kN"], [400u"kN*m"], geoms, ConcreteColumnOptions())
size_columns([500kip], [300kip*u"ft"], geoms, ConcreteColumnOptions())
size_columns([500.0], [300.0], geoms, ConcreteColumnOptions())  # Raw Float64 assumed kip, kip·ft
```

Unit helpers: `to_kip(x)`, `to_kipft(x)` for US customary; `to_newtons(x)`, `to_newton_meters(x)` for SI. Raw `Real` values pass through as-is (assumed correct units).

## Quick Start

```julia
using StructuralSizer
using Unitful

# Define section (18"×18" with 8-#8 bars)
section = RCColumnSection(
    b = 18u"inch", h = 18u"inch",
    bar_size = 8, n_bars = 8,
    cover = 2.5u"inch", tie_type = :tied
)

# Material
material = RC_4000_60  # 4 ksi concrete + Grade 60 rebar

# Generate P-M diagram
diagram = generate_PM_diagram(section, material)

# Check capacity
result = check_PM_capacity(diagram, 300.0, 150.0)  # Pu=300 kip, Mu=150 kip-ft
# result.adequate     → true/false
# result.utilization  → demand/capacity ratio
# result.φMn_at_Pu    → moment capacity at given axial
```

## Key Types

### P-M Interaction Diagram

```@docs
PMInteractionDiagram
```

`PMInteractionDiagram{S, M}` stores the interaction diagram for a section `S` with material `M`:

| Field | Description |
|:------|:------------|
| `section` | The column section (`RCColumnSection` or `RCCircularSection`) |
| `material` | Concrete material |
| `points` | Vector of `(ϕPn, ϕMn)` tuples forming the interaction curve |
| `control_points` | Dictionary mapping `ControlPointType` to indices |

```@docs
PMDiagramRect
```

Type alias: `PMInteractionDiagram{RCColumnSection}` — for rectangular columns.

```@docs
PMDiagramCircular
```

Type alias: `PMInteractionDiagram{RCCircularSection}` — for circular columns.

### Control Points

```@docs
ControlPointType
```

```@docs
PMDiagramPoint
```

`@enum ControlPointType` identifies key points on the interaction diagram:

| Value | Description |
|:------|:------------|
| `PURE_COMPRESSION` | ϕPn_max = ϕ × 0.80 × P0 (tied) or ϕ × 0.85 × P0 (spiral) |
| `MAX_COMPRESSION` | Maximum unreduced compression capacity |
| `FS_ZERO` | Extreme tension fiber strain = 0 |
| `FS_HALF_FY` | Extreme tension steel at fy/2 |
| `BALANCED` | Simultaneous concrete crushing and steel yielding (εs = εy) |
| `TENSION_CONTROLLED` | εt = 0.005 (transition point for φ = 0.90) |
| `PURE_BENDING` | Pu = 0, maximum moment capacity |
| `PURE_TENSION` | ϕTn = ϕ × As_total × fy |
| `INTERMEDIATE` | Interpolated points between control points |

### Checker & Cache

```@docs
ACIColumnChecker
```

`ACIColumnChecker <: AbstractCapacityChecker` carries design parameters:

| Field | Description |
|:------|:------------|
| `include_slenderness` | Whether to apply slenderness magnification |
| `include_biaxial` | Whether to check biaxial bending |
| `α_biaxial` | Exponent for PCA load contour method |
| `fy_ksi` | Rebar yield strength (ksi) |
| `Es_ksi` | Steel elastic modulus (ksi) |
| `max_depth` | Maximum column dimension constraint |

```@docs
ACIColumnCapacityCache
```

`ACIColumnCapacityCache` stores precomputed interaction diagrams for each catalog section.

## Functions

### P-M Diagram Generation

```@docs
generate_PM_diagram
```

`generate_PM_diagram(section, mat; n_intermediate=20)` — generates the full P-M interaction diagram by strain compatibility analysis. The algorithm:

1. Compute strain profiles for each control point (c from 0 to ∞)
2. At each neutral axis depth `c`, compute bar strains from linear strain distribution
3. Sum bar forces and moments about the centroid
4. Apply strength reduction factor `φ` per §21.2.2 (varies from 0.65/0.75 to 0.90)
5. Add `n_intermediate` points between control points for smooth interpolation

### Capacity Checks

```@docs
check_PM_capacity
```

`check_PM_capacity(diagram, Pu, Mu)` — returns a `NamedTuple`; use `result.adequate` (Bool) and `result.utilization` (Float64) to interpret the check.

```@docs
capacity_at_axial
```

`capacity_at_axial(diagram, Pu)` — returns the moment capacity `ϕMn` at a given axial load level by interpolating on the diagram.

```@docs
capacity_at_moment
```

`capacity_at_moment(diagram, Mu)` — returns the axial capacity `ϕPn` at a given moment level.

```@docs
utilization_ratio
```

`utilization_ratio(diagram, Pu, Mu)` — returns a scalar utilization ratio (≤ 1.0 is adequate). Computed by finding the intersection of the load ray with the interaction curve.

### Biaxial Bending (ACI §22.4)

```@docs
bresler_reciprocal_load
```

`bresler_reciprocal_load(Pnx, Pny, P0)` — Bresler reciprocal load method:

```math
\frac{1}{P_n} = \frac{1}{P_{nx}} + \frac{1}{P_{ny}} - \frac{1}{P_0}
```

where ``P_{nx}`` = nominal axial capacity at eccentricity ``e_x`` only, ``P_{ny}`` at ``e_y`` only, ``P_0`` = pure axial capacity. Valid when ``P_n / P_0 \geq 0.1``.

```@docs
pca_load_contour
```

`pca_load_contour(Mux, Muy, φMnox, φMnoy, Pu, φPn, φP0; β=0.65)` — PCA load contour method:

```math
\left(\frac{M_{ux}}{\phi M_{nox}}\right)^\alpha + \left(\frac{M_{uy}}{\phi M_{noy}}\right)^\alpha \leq 1.0
```

where ``\alpha \approx 1.5`` for typical columns (``\beta`` maps to ``\alpha`` via ``\alpha = \log 0.5 / \log \beta``).

```@docs
check_biaxial_capacity
```

`check_biaxial_capacity(diagram_x, diagram_y, Pu, Mux, Muy; method=:contour, α=1.5)` — biaxial check using either `:bresler` or `:contour` method. Requires separate P-M diagrams for each axis.

### Slenderness (ACI 318-11 §10.10)

```@docs
slenderness_ratio
```

`slenderness_ratio(section, geometry)` — computes ``kL_u/r`` per ACI 318-11 §10.10.1.2. Uses ``r = 0.3h`` for rectangular sections and ``r = 0.25D`` for circular sections.

```@docs
magnification_factor_nonsway
```

`magnification_factor_nonsway(Pu, Pc; Cm=1.0)` — moment magnification factor for nonsway frames (ACI 318-11 §10.10.6.3):

```math
\delta_{ns} = \frac{C_m}{1 - \dfrac{P_u}{0.75\,P_c}} \geq 1.0
```

where ``P_c = \pi^2 EI / (k L_u)^2`` is the Euler buckling load using the effective stiffness ``EI``.

```@docs
magnify_moment_nonsway
```

`magnify_moment_nonsway(section, mat, geometry, Pu, M1, M2; βdns, transverse_load)` — complete nonsway moment magnification. Computes `EI` per ACI 318-11 §10.10.6.1:

```math
EI = \frac{0.2\,E_c\,I_g + E_s\,I_{se}}{1 + \beta_{dns}} \quad \text{or} \quad EI = \frac{0.4\,E_c\,I_g}{1 + \beta_{dns}}
```

Then computes ``P_c``, ``C_m``, and ``\delta_{ns}``.

### Sway Properties

```@docs
SwayStoryProperties
```

`SwayStoryProperties` stores story-level data for sway magnification:

| Field | Description |
|:------|:------------|
| `ΣPu` | Total factored vertical load in the story |
| `ΣPc` | Total Euler buckling load for all columns in the story |
| `Vus` | Story shear |
| `Δo` | First-order interstory drift |
| `lc` | Story height |

```@docs
stability_index
```

`stability_index(story)` — stability index Q per ACI 318-11 §10.10.5.2:

```math
Q = \frac{\sum P_u \cdot \Delta_o}{V_{us} \cdot l_c}
```

If ``Q \leq 0.05``, the story is classified as nonsway.

## Implementation Details

### Strain Compatibility

The P-M diagram is generated using a full strain compatibility analysis at each neutral axis depth ``c``. The concrete compressive force uses the Whitney stress block (``a = \beta_1 c``), and each bar's stress is determined from its strain (assuming elastic-perfectly-plastic steel behavior):

```math
\varepsilon_{si} = \varepsilon_{cu} \cdot \frac{c - d_i}{c}
```

where ``\varepsilon_{cu} = 0.003``, ``d_i`` is the distance from the extreme compression fiber to bar ``i``. Forces are summed and moments taken about the plastic centroid.

### Strength Reduction Factor φ

The ``\phi`` factor varies linearly between the compression-controlled value and the tension-controlled value based on the extreme tension steel strain ``\varepsilon_t``:

- ``\varepsilon_t \leq \varepsilon_y``: ``\phi = 0.65`` (tied) or ``0.75`` (spiral) — compression controlled
- ``\varepsilon_y < \varepsilon_t < 0.005``: linear interpolation — transition zone
- ``\varepsilon_t \geq 0.005``: ``\phi = 0.90`` — tension controlled

### Maximum Compression Cap

ACI limits the maximum axial load to prevent pure compression failure:

```math
\phi P_{n,\max} = \phi \cdot \alpha \left[0.85\,f'_c\,(A_g - A_{st}) + f_y\,A_{st}\right]
```

where ``\alpha = 0.80`` for tied columns and ``0.85`` for spiral columns.

### Biaxial Method Selection

The PCA load contour method (`:contour`) is generally preferred for design because it uses the moment interaction directly. The Bresler reciprocal load method (`:bresler`) is simpler but less accurate for low axial loads (`Pn/P0 < 0.1`).

## ACIColumnChecker (Optimization Interface)

For discrete optimization, `ACIColumnChecker` caches P-M diagrams and checks feasibility efficiently:

```julia
checker = ACIColumnChecker(;
    include_slenderness = true,   # Apply moment magnification
    include_biaxial = true,       # Check biaxial interaction
    α_biaxial = 1.5,              # Bresler exponent
    fy_ksi = 60.0,                # Rebar yield strength
    Es_ksi = Es_ksi(Rebar_60),     # Rebar elastic modulus
    max_depth = 0.6               # Max section depth [m]
)

# Setup catalog
catalogue = standard_rc_columns()  # Or custom catalog
cache = create_cache(checker, length(catalogue))
precompute_capacities!(checker, cache, catalogue, NWC_4000, MinVolume())

# Define demand (with end moments for Cm)
demand = RCColumnDemand(1;
    Pu = 500.0,          # kip (compression positive)
    Mux = 150.0,         # kip-ft
    Muy = 75.0,          # kip-ft (biaxial)
    M1x = 100.0,         # Smaller end moment (for Cm)
    M2x = 150.0,         # Larger end moment
    βdns = 0.6           # Sustained load ratio
)

# Define geometry
geometry = ConcreteMemberGeometry(3.66;  # L = 12 ft in meters
    Lu = 3.66,           # Unsupported length
    k = 1.0,             # Effective length factor
    braced = true        # Braced frame
)

# Check feasibility
feasible = is_feasible(checker, cache, j, section, material, demand, geometry)
```

When `include_slenderness = false`, the checker skips moment magnification (appropriate when second-order effects are captured in the analysis). When `include_biaxial = false`, only uniaxial P-M checks are performed.

## Chapter Coverage

### P-M Interaction (Chapter 10 — Sectional Strength)

Strain compatibility analysis with Whitney stress block:

```julia
diagram = generate_PM_diagram(section, mat; n_intermediate=20)

curve = get_factored_curve(diagram)        # (φPn, φMn) arrays
control = get_control_points(diagram)      # Key points only
balanced = get_control_point(diagram, :balanced)
# balanced.Pn, balanced.Mn, balanced.φ, balanced.εt

φMn = capacity_at_axial(diagram, Pu)       # Moment capacity at Pu
φPn = capacity_at_moment(diagram, Mu)      # Axial capacity at Mu
```

**Control Points (per StructurePoint methodology):**
1. Pure compression (P₀)
2. Maximum compression (Pn,max = α·P₀)
3. fs = 0 (c = d)
4. fs = 0.5fy
5. Balanced (fs = fy, εt = εy)
6. Tension controlled (εt = εy + 0.003)
7. Pure bending (Pn ≈ 0)
8. Pure tension

### Slenderness Effects (Chapter 10 — Moment Magnification)

Non-sway frame magnification per §10.10.6:

```julia
slender = should_consider_slenderness(section, geometry; M1=M1, M2=M2)
λ = slenderness_ratio(section, geometry)   # kLu/r

EI_eff = effective_stiffness(section, mat; βdns=0.6, method=:accurate)
# method=:accurate    → (0.2·Ec·Ig + Es·Ise) / (1 + βdns)
# method=:simplified  → 0.4·Ec·Ig / (1 + βdns)

Pc = critical_buckling_load(section, mat, geometry; βdns=0.6)
Cm = calc_Cm(M1, M2; transverse_load=false)  # 0.6 - 0.4(M1/M2) ≥ 0.4
δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)

result = magnify_moment_nonsway(section, mat, geometry, Pu, M1, M2; βdns=0.6)
# result.Mc, result.δns, result.Cm, result.Pc, result.slender
```

**Slenderness Limits (ACI §10.10.1):**
- Braced: kLu/r ≤ 34 − 12(M1/M2), max 40
- Sway: kLu/r ≤ 22

**Radius of Gyration:** r = 0.3h (rectangular), r = 0.25D (circular)

### Sway Frame Functions (Not Integrated)

Functions exist for sway frame analysis but are not yet wired into the checker:

```julia
story = SwayStoryProperties(
    ΣPu = 2000.0, ΣPc = 5000.0,  # Total factored / critical loads (kip)
    Vus = 100.0, Δo = 0.5,        # Story shear (kip), drift (in)
    lc = 144.0                     # Story height (in)
)

Q = stability_index(story)         # Q > 0.05 → sway frame
δs = magnification_factor_sway_Q(Q)  # δs = 1/(1−Q)

result = magnify_moment_sway_complete(
    section, mat, geometry,
    Pu, M1ns, M2ns, M1s, M2s;
    story = story, βds = 0.0, βdns = 0.6
)
```

### Biaxial Bending

Multiple methods for biaxial interaction:

```julia
# Bresler Load Contour (default, used by checker)
util = bresler_load_contour(Mux, Muy, φMnx, φMny; α=1.5)
# (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1.0

# Bresler Reciprocal Load (for high P / low M)
Pn = bresler_reciprocal_load(Pnx, Pny, P0)
# 1/Pn = 1/Pnx + 1/Pny - 1/P0

# Full check with separate x/y diagrams
diagrams = generate_PM_diagrams_biaxial(section, mat)
result = check_biaxial_capacity(diagrams.x, diagrams.y, Pu, Mux, Muy; method=:contour)
```

**Methods:** `:contour` (Bresler Load Contour, recommended, α ≈ 1.5) or `:reciprocal` (Bresler Reciprocal Load, high axial cases).

## Material Utilities

Unified material property functions in `aci_material_utils.jl`:

```julia
β₁ = beta1(material)     # 0.85 for f'c ≤ 4 ksi, reduces to 0.65 at 8 ksi
Ec = Ec(material)         # Unitful quantity
Ec_val = Ec_ksi(mat)      # Float64 in ksi
fr_val = fr(material)     # Modulus of rupture: 7.5√f'c (psi)

# Property extractors (work with Concrete, ReinforcedConcreteMaterial, or NamedTuple)
fc = fc_ksi(mat)          # f'c in ksi
fy = fy_ksi(mat)          # fy in ksi
Es = Es_ksi(mat)          # Es in ksi
ε = εcu(mat)              # Ultimate strain (0.003)

mat_tuple = to_material_tuple(material, fy_ksi, Es_ksi)
```

## Limitations & Future Work

### Not Implemented

| Feature | ACI Reference | Notes |
|:--------|:--------------|:------|
| Sway Frame Amplification (δs) | §10.10.7 | Functions exist (`magnify_moment_sway_complete`) but not integrated into `ACIColumnChecker`. |
| Shear Design | Chapter 10 | No column shear capacity or shear reinforcement design. |
| Confinement Detailing | 25.7.2, 25.7.3 | Tie spacing and hoop requirements not checked; section geometry only. |
| Lap Splice Design | 25.5 | No splice length or location checks. |
| Development Length | 25.4 | No bar anchorage or embedment checks. |
| Seismic Provisions | Chapter 18 | No special moment frame detailing or confinement requirements. |
| Fire Design | — | No cover requirements for fire rating. |
| Crack Control | 24.3 | No service-level crack width checks. |
| Beam Design | Chapter 9 | Beam stubs exist but not fully implemented. |
| Walls | — | High aspect ratio columns use the same P-M approach; no wall-specific provisions. |

### Simplifying Assumptions

| Assumption | Impact | Mitigation |
|:-----------|:-------|:-----------|
| βdns = 0.6 default | Conservative sustained load ratio | Override with actual βdns from load analysis |
| k = 1.0 default | Conservative for braced frames | Provide actual k from alignment charts |
| Grade 60 rebar default | Standard assumption | Override with `rebar_material` (e.g., `Rebar_75`) |
| Es = 29,000 ksi | Standard steel modulus | Embedded in calculations |
| εcu = 0.003 | ACI concrete crushing strain | Used for all calculations |
| Whitney stress block | ACI §10.2.7 equivalent rectangular | Accurate for normal strength concrete |
| α = 1.5 for biaxial | Bresler Load Contour exponent | Override with `α_biaxial` parameter |

### Section Type Limitations

| Section | Supported | Not Supported |
|:--------|:----------|:--------------|
| Rectangular (`RCColumnSection`) | Full P-M, biaxial, slenderness | Shear, detailing |
| Circular (`RCCircularSection`) | Full P-M, slenderness | Biaxial (axisymmetric) |
| L-shaped, T-shaped | — | Not yet implemented |
| Walls | — | Not yet implemented |

## API Summary

### P-M Diagram Functions

| Function | Description |
|:---------|:------------|
| `generate_PM_diagram(section, mat)` | Generate full P-M interaction diagram |
| `generate_PM_diagrams_biaxial(section, mat)` | Both x and y diagrams |
| `check_PM_capacity(diagram, Pu, Mu)` | Check demand against diagram |
| `capacity_at_axial(diagram, Pu)` | φMn at given Pu |
| `capacity_at_moment(diagram, Mu)` | φPn at given Mu |
| `get_factored_curve(diagram)` | (φPn, φMn) arrays |
| `get_control_point(diagram, :balanced)` | Specific control point |

### Slenderness Functions

| Function | ACI Reference | Description |
|:---------|:--------------|:------------|
| `slenderness_ratio(section, geometry)` | §10.10.1.2 | kLu/r calculation |
| `should_consider_slenderness(...)` | §10.10.1 | Check against limits |
| `effective_stiffness(section, mat)` | §10.10.6.1 | (EI)eff calculation |
| `critical_buckling_load(section, mat, geo)` | §10.10.6.1 | Pc = π²(EI)eff/(kLu)² |
| `calc_Cm(M1, M2)` | §10.10.6.4 | Equivalent moment factor |
| `magnification_factor_nonsway(Pu, Pc)` | §10.10.6.3 | δns factor |
| `magnify_moment_nonsway(...)` | §10.10.6 | Complete magnification |

### Sway Frame Functions

| Function | ACI Reference | Description |
|:---------|:--------------|:------------|
| `SwayStoryProperties(...)` | §10.10 | Story data container (ΣPu, ΣPc, Vus, Δo, lc) |
| `stability_index(story)` | §10.10.5.2 | Q = ΣPu·Δo / (Vus·lc) |
| `is_sway_frame(story)` | §10.10.5.2 | Q > 0.05 → sway |
| `magnification_factor_sway_Q(Q)` | §10.10.7.3(a) | δs = 1/(1−Q) |
| `magnify_moment_sway_complete(...)` | §10.10.6–7 | Full sway magnification |

### Biaxial Functions

| Function | Method | Description |
|:---------|:-------|:------------|
| `bresler_load_contour(...)` | Bresler | (Mux/φMnx)^α + (Muy/φMny)^α |
| `bresler_reciprocal_load(...)` | Bresler | 1/Pn = 1/Pnx + 1/Pny − 1/P0 |
| `pca_load_contour(...)` | PCA | Linear contour with β factor |
| `check_biaxial_capacity(...)` | Full | Uses separate x/y diagrams |
| `check_biaxial_auto(...)` | Auto | Detects square vs rectangular |

### Checker Interface

| Function | Description |
|:---------|:------------|
| `ACIColumnChecker(; ...)` | Create checker with options |
| `create_cache(checker, n)` | Create P-M diagram cache |
| `precompute_capacities!(...)` | Precompute all diagrams |
| `is_feasible(...)` | Check section feasibility |

## References

- ACI 318-11: Building Code Requirements for Structural Concrete
- StructurePoint spColumn Design Examples (verification source)
- PCA Notes on ACI 318 (biaxial methods)
- Bresler, B. (1960) "Design Criteria for Reinforced Columns Under Axial Load and Biaxial Bending"
