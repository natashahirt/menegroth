# ACI Reinforced Concrete Column Design

ACI 318-11 capacity checks for reinforced concrete columns. Covers P-M interaction diagrams, slenderness effects (moment magnification), and biaxial bending.

---

## Limitations & Assumptions

### Not Implemented

| Feature | ACI Reference | Notes |
|---------|---------------|-------|
| **Sway Frame Amplification (δs)** | §10.10.7 | Functions exist (`magnify_moment_sway_complete`) but not integrated into `ACIColumnChecker`. Set `geometry.braced=false` to flag sway frames. |
| **Shear Design** | Chapter 10 | No column shear capacity or shear reinforcement design. |
| **Confinement Detailing** | 25.7.2, 25.7.3 | Tie spacing and hoop requirements not checked; section geometry only. |
| **Lap Splice Design** | 25.5 | No splice length or location checks. |
| **Development Length** | 25.4 | No bar anchorage or embedment checks. |
| **Seismic Provisions** | Chapter 18 | No special moment frame detailing or confinement requirements. |
| **Fire Design** | — | No cover requirements for fire rating. |
| **Crack Control** | 24.3 | No service-level crack width checks. |
| **Beam Design** | Chapter 9 | Beam stubs exist but not fully implemented. |

### Simplifying Assumptions

| Assumption | Impact | Mitigation |
|------------|--------|------------|
| **βdns = 0.6 default** | Conservative sustained load ratio | Override with actual βdns from load analysis |
| **k = 1.0 default** | Conservative for braced frames | Provide actual k from alignment charts |
| **Grade 60 rebar default** | Standard assumption | Override with `rebar_grade` (e.g., `Rebar_75`) |
| **Es = 29,000 ksi** | Standard steel modulus | Embedded in calculations |
| **εcu = 0.003** | ACI concrete crushing strain | Used for all calculations |
| **Whitney stress block** | ACI §10.2.7 equivalent rectangular | Accurate for normal strength concrete |
| **α = 1.5 for biaxial** | Bresler Load Contour exponent | Override with `α_biaxial` parameter |

### Section Type Limitations

| Section | Supported | Not Supported |
|---------|-----------|---------------|
| **Rectangular (RCColumnSection)** | ✅ Full P-M, biaxial, slenderness | Shear, detailing |
| **Circular (RCCircularSection)** | ✅ Full P-M, slenderness | Biaxial (axisymmetric) |
| **L-shaped, T-shaped** | ❌ | Not yet implemented |
| **Walls** | ❌ | Not yet implemented |

### Design Philosophy

- **LRFD only** — Strength design with φ factors per §9.3.2
- **US units internally** — kip, kip-ft, inches (accepts Unitful, converts internally)
- **Strain compatibility** — Full fiber analysis, not approximate methods
- **Catalog-based optimization** — Sections from predefined catalogs

### Units & Input Flexibility

The API accepts **any Unitful quantity** — conversions are automatic:

```julia
using StructuralSizer: kip  # Asap custom unit
# Standard Unitful units (kN, m, ft) available via u"..."

# All equivalent — units converted internally to ACI (kip, kip·ft)
size_columns([2200u"kN"], [400u"kN*m"], geoms, ConcreteColumnOptions())
size_columns([500kip], [300kip*u"ft"], geoms, ConcreteColumnOptions())
size_columns([500.0], [300.0], geoms, ConcreteColumnOptions())  # Raw Float64 assumed kip, kip·ft
```

Unit helpers from `Asap` handle the conversion:
- `to_kip(x)`, `to_kipft(x)` — for ACI (US customary)
- `to_newtons(x)`, `to_newton_meters(x)` — for SI
- Pass-through for `Real` types (assumed correct units)

---

## Supported Section Types

| Type | Module | Description |
|------|--------|-------------|
| `RCColumnSection` | `column_pm_rect.jl` | Rectangular tied/spiral columns |
| `RCCircularSection` | `column_pm_circular.jl` | Circular spiral/tied columns |

---

## Quick Start

```julia
using StructuralSizer
using Unitful

# Define section (18"×18" with 8-#8 bars)
section = RCColumnSection(
    b = 18u"inch", h = 18u"inch",
    bars = standard_bar_layout(8, 8, 18u"inch", 18u"inch", 2.5u"inch"),
    tie_type = :tied
)

# Material
material = NWC_4000  # 4 ksi normal weight concrete

# Generate P-M diagram
mat = (fc = 4.0, fy = 60.0, Es = 29000.0, εcu = 0.003)
diagram = generate_PM_diagram(section, mat)

# Check capacity
result = check_PM_capacity(diagram, 300.0, 150.0)  # Pu=300 kip, Mu=150 kip-ft
# result.adequate     → true/false
# result.utilization  → demand/capacity ratio
# result.φMn_at_Pu    → moment capacity at given axial
```

---

## ACIColumnChecker (Optimization Interface)

For discrete optimization, use `ACIColumnChecker` which caches P-M diagrams:

```julia
# Create checker with options
checker = ACIColumnChecker(;
    include_slenderness = true,   # Apply moment magnification
    include_biaxial = true,       # Check biaxial interaction
    α_biaxial = 1.5,              # Bresler exponent
    fy_ksi = 60.0,                # Rebar yield strength
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

---

## Chapter Coverage

### Chapter 10 — Sectional Strength (P-M Interaction)

Strain compatibility analysis with Whitney stress block.

```julia
# Generate full P-M diagram
diagram = generate_PM_diagram(section, mat; n_intermediate=20)

# Access curve data
curve = get_factored_curve(diagram)  # (φPn, φMn) arrays
control = get_control_points(diagram) # Key points only

# Get specific control point
balanced = get_control_point(diagram, :balanced)
# balanced.Pn, balanced.Mn, balanced.φ, balanced.εt

# Capacity at given demand
φMn = capacity_at_axial(diagram, Pu)   # Moment capacity at Pu
φPn = capacity_at_moment(diagram, Mu)  # Axial capacity at Mu
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

**Equations:**
- Whitney β₁: §10.2.7
- φ factor: §9.3.2 (0.65-0.90 transition)
- Steel stress: εs × Es, capped at ±fy

### Chapter 10 — Slenderness Effects (Moment Magnification)

Non-sway frame magnification per §10.10.6.

```julia
# Check if slenderness matters
slender = should_consider_slenderness(section, geometry; M1=M1, M2=M2)

# Calculate slenderness ratio
λ = slenderness_ratio(section, geometry)  # kLu/r

# Effective stiffness
EI_eff = effective_stiffness(section, mat; βdns=0.6, method=:accurate)
# method=:accurate → (0.2·Ec·Ig + Es·Ise) / (1 + βdns)
# method=:simplified → 0.4·Ec·Ig / (1 + βdns)

# Critical buckling load
Pc = critical_buckling_load(section, mat, geometry; βdns=0.6)

# Cm factor (equivalent uniform moment)
Cm = calc_Cm(M1, M2; transverse_load=false)
# Cm = 0.6 - 0.4(M1/M2) ≥ 0.4

# Magnification factor
δns = magnification_factor_nonsway(Pu, Pc; Cm=Cm)
# δns = Cm / (1 - Pu/(0.75·Pc)) ≥ 1.0

# Complete magnification (used by checker)
result = magnify_moment_nonsway(section, mat, geometry, Pu, M1, M2; βdns=0.6)
# result.Mc    → Magnified design moment
# result.δns   → Magnification factor
# result.Cm    → Cm value used
# result.Pc    → Critical buckling load
# result.slender → Whether slenderness was considered
```

**Slenderness Limits (ACI §10.10.1):**
- Braced: kLu/r ≤ 34 - 12(M1/M2), max 40
- Sway: kLu/r ≤ 22

**Radius of Gyration:**
- Rectangular: r = 0.3h
- Circular: r = 0.25D

### Sway Frame Functions (Not Integrated)

Functions exist for sway frame analysis but are not yet wired into the checker:

```julia
# Story properties for sway analysis
story = SwayStoryProperties(
    ΣPu = 2000.0,    # Total factored vertical load (kip)
    ΣPc = 5000.0,    # Sum of critical loads (kip)
    Vus = 100.0,     # Factored story shear (kip)
    Δo = 0.5,        # First-order drift (in)
    lc = 144.0       # Story height (in)
)

# Stability index
Q = stability_index(story)  # Q > 0.05 → sway frame
is_sway = is_sway_frame(story)

# Sway magnification factor
δs = magnification_factor_sway_Q(Q)  # δs = 1/(1-Q)

# Complete sway magnification
result = magnify_moment_sway_complete(
    section, mat, geometry,
    Pu, M1ns, M2ns, M1s, M2s;
    story = story,
    βds = 0.0,        # Sustained shear ratio (0 for wind)
    βdns = 0.6
)
```

### Biaxial Bending

Multiple methods for biaxial interaction checks.

```julia
# Bresler Load Contour (default, used by checker)
util = bresler_load_contour(Mux, Muy, φMnx, φMny; α=1.5)
# (Mux/φMnx)^α + (Muy/φMny)^α ≤ 1.0

# Bresler Reciprocal Load (for high P/low M)
Pn = bresler_reciprocal_load(Pnx, Pny, P0)
# 1/Pn = 1/Pnx + 1/Pny - 1/P0

# PCA Load Contour
util = pca_load_contour(Mux, Muy, φMnox, φMnoy, Pu, φPn, φP0; β=0.65)

# Full check with separate x/y diagrams (for rectangular b ≠ h)
diagrams = generate_PM_diagrams_biaxial(section, mat)
result = check_biaxial_capacity(diagrams.x, diagrams.y, Pu, Mux, Muy; method=:contour)

# Auto-detect square vs rectangular
result = check_biaxial_auto(section, mat, Pu, Mux, Muy; α=1.5)
```

**Biaxial Methods:**
- `:contour` — Bresler Load Contour (recommended, α typically 1.5)
- `:reciprocal` — Bresler Reciprocal Load (high axial cases)

---

## Material Utilities

Unified material property functions in `aci_material_utils.jl`:

```julia
# Whitney stress block factor
β₁ = beta1(material)  # 0.85 for f'c ≤ 4 ksi, reduces to 0.65 at 8 ksi

# Concrete modulus
Ec = Ec(material)      # Returns Unitful quantity
Ec_val = Ec_ksi(mat)   # Returns Float64 in ksi

# Modulus of rupture
fr_val = fr(material)  # 7.5√f'c (psi)

# Property extractors (work with Concrete, ReinforcedConcreteMaterial, or NamedTuple)
fc = fc_ksi(mat)   # f'c in ksi
fy = fy_ksi(mat)   # fy in ksi
Es = Es_ksi(mat)   # Es in ksi
ε = εcu(mat)       # Ultimate strain (0.003)

# Convert to legacy tuple format
mat_tuple = to_material_tuple(material, fy_ksi, Es_ksi)
```

---

## Strength Reduction Factor (φ)

Per ACI 318-11 §9.3.2:

```julia
φ = phi_factor(εt, :tied; fy_ksi=60.0)
```

| εt Range | φ (Tied) | φ (Spiral) | Classification |
|----------|----------|------------|----------------|
| εt ≤ εy | 0.65 | 0.75 | Compression controlled |
| εy < εt < εy+0.003 | 0.65→0.90 | 0.75→0.90 | Transition |
| εt ≥ εy+0.003 | 0.90 | 0.90 | Tension controlled |

Where εy = fy/Es (≈0.00207 for Grade 60)

---

## File Structure

```
aci/
├── _aci.jl                  # Module aggregation
├── README.md                # This file
├── aci_material_utils.jl    # β₁, Ec, fr, extractors
├── checker.jl               # ACIColumnChecker (optimization)
├── slenderness.jl           # Moment magnification (δns, δs)
├── biaxial.jl               # Bresler methods
├── column_pm_rect.jl        # Rectangular P-M diagrams
├── column_pm_circular.jl    # Circular P-M diagrams
└── reference/               # StructurePoint design examples
    ├── beams/               # Beam examples (not implemented)
    └── columns/             # Column verification examples
```

---

## API Summary

### P-M Diagram Functions

| Function | Description |
|----------|-------------|
| `generate_PM_diagram(section, mat)` | Generate full P-M interaction diagram |
| `generate_PM_diagram_yaxis(section, mat)` | Y-axis diagram for rectangular biaxial |
| `generate_PM_diagrams_biaxial(section, mat)` | Both x and y diagrams |
| `check_PM_capacity(diagram, Pu, Mu)` | Check demand against diagram |
| `capacity_at_axial(diagram, Pu)` | φMn at given Pu |
| `capacity_at_moment(diagram, Mu)` | φPn at given Mu |
| `get_factored_curve(diagram)` | (φPn, φMn) arrays |
| `get_control_point(diagram, :balanced)` | Specific control point |

### Slenderness Functions

| Function | ACI Reference | Description |
|----------|---------------|-------------|
| `slenderness_ratio(section, geometry)` | §10.10.1.2 | kLu/r calculation |
| `should_consider_slenderness(...)` | §10.10.1 | Check against limits |
| `effective_stiffness(section, mat)` | §10.10.6.1 | (EI)eff calculation |
| `critical_buckling_load(section, mat, geo)` | §10.10.6.1 | Pc = π²(EI)eff/(kLu)² |
| `calc_Cm(M1, M2)` | §10.10.6.4 | Equivalent moment factor |
| `magnification_factor_nonsway(Pu, Pc)` | §10.10.6.3 | δns factor |
| `magnify_moment_nonsway(...)` | §10.10.6 | Complete magnification |

### Sway Frame Functions

| Function | ACI Reference | Description |
|----------|---------------|-------------|
| `SwayStoryProperties(...)` | §10.10 | Story data container (ΣPu, ΣPc, Vus, Δo, lc) |
| `stability_index(story)` | §10.10.5.2 | Q = ΣPu·Δo / (Vus·lc) |
| `is_sway_frame(story)` | §10.10.5.2 | Q > 0.05 → sway |
| `magnification_factor_sway_Q(Q)` | §10.10.7.3(a) | δs = 1/(1-Q) |
| `magnify_moment_sway_complete(...)` | §10.10.6-7 | Full sway magnification |

### Biaxial Functions

| Function | Method | Description |
|----------|--------|-------------|
| `bresler_load_contour(...)` | Bresler | (Mux/φMnx)^α + (Muy/φMny)^α |
| `bresler_reciprocal_load(...)` | Bresler | 1/Pn = 1/Pnx + 1/Pny - 1/P0 |
| `pca_load_contour(...)` | PCA | Linear contour with β factor |
| `check_biaxial_capacity(...)` | Full | Uses separate x/y diagrams |
| `check_biaxial_auto(...)` | Auto | Detects square vs rectangular |

### Checker Interface

| Function | Description |
|----------|-------------|
| `ACIColumnChecker(; ...)` | Create checker with options |
| `create_cache(checker, n)` | Create P-M diagram cache |
| `precompute_capacities!(...)` | Precompute all diagrams |
| `is_feasible(...)` | Check section feasibility |

---

## Units

Internal calculations use US customary (kip, kip-ft, inches). Functions accept Unitful and convert automatically:

```julia
# Unitful input
demand = RCColumnDemand(1; 
    Pu = 2000u"kN",           # Converted to kip internally
    Mux = 300u"kN*m"          # Converted to kip-ft internally
)

# Or direct US units (no conversion)
demand = RCColumnDemand(1;
    Pu = 450.0,               # kip
    Mux = 220.0               # kip-ft
)
```

---

## References

- ACI 318-11: Building Code Requirements for Structural Concrete
- StructurePoint spColumn Design Examples (verification source)
- PCA Notes on ACI 318 (biaxial methods)
- Bresler, B. (1960) "Design Criteria for Reinforced Columns Under Axial Load and Biaxial Bending"
