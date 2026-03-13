# AISC Steel Member Design

AISC 360-16 capacity checks for steel members. Covers compression, flexure, shear, tension, torsion, combined interaction, second-order effects (B1/B2), and **composite beam design (Chapter I)**.

---

## Limitations & Assumptions

### Not Implemented

| Feature | AISC Reference | Notes |
|---------|----------------|-------|
| **Sway Frame Amplification (B2)** | Appendix 8 | B2 functions exist but are not integrated into `AISCChecker`. Set `geometry.braced=false` to flag sway frames, but amplification must be applied externally. |
| **Connection Design** | Chapter J | No bolt/weld capacity, block shear, prying action, or connection detailing. This package sizes members only. |
| **Web Crippling / Local Bearing** | J10 | Concentrated load checks at supports and load points not implemented. |
| **Built-up Sections** | E6 | Modified slenderness for built-up columns not implemented. |
| **Single-Angle Members** | Chapter E, F | Special provisions for single angles not implemented. |
| **Asymmetric I-Shapes** | — | Only doubly symmetric W/S shapes supported; no channels, WT, or singly symmetric I. |
| **Composite Columns** | I2 | Composite beams (I3) are implemented; composite columns are not. |
| **Formed Metal Deck (parallel wr/hr < 1.5)** | I3.2c | `DeckSlabOnBeam` is fully implemented for perpendicular deck and parallel deck with wr/hr ≥ 1.5. Parallel deck with wr/hr < 1.5 uses conservative Rg=0.85 but may need additional rib-level checks for heavily loaded configurations. |
| **Elastic Stress Distribution** | I3.2a(b) | When h/tw > 3.76√(E/Fy), the elastic method is required. A `NotImplementedError` is raised — only plastic stress distribution (I3.2a(a)) is implemented. |
| **Seismic Provisions** | AISC 341 | No seismic compactness, expected strengths, or special detailing. |
| **Fire Design** | Appendix 4 | No elevated temperature capacity reduction. |
| **Fatigue** | Appendix 3 | No fatigue/cyclic loading checks. |

### Simplifying Assumptions

| Assumption | Impact | Mitigation |
|------------|--------|------------|
| **Ae = 0.75·Ag for tension rupture** | Conservative for most connections | Override with `Ae_ratio` parameter |
| **Cb = 1.0 default** | Conservative for moment gradient | Provide actual Cb from analysis |
| **K = 1.0 default** | Conservative for braced frames; unconservative for sway | Provide actual K from alignment charts |
| **Shear Lv = L default** | Conservative for distributed loads | Provide Lv (distance from max to zero shear) for accuracy |
| **Deflection uses linear scaling** | Approximate for moment-controlled beams | Acceptable for typical cases |
| **No stiffener design** | Affects shear/bearing capacity | Use rolled shapes within web limits |

### Section Type Limitations

| Section | Supported | Not Supported |
|---------|-----------|---------------|
| **W-shapes** | ✅ Compression, flexure, shear, tension | Torsion (use HSS for significant torsion) |
| **HSS Rect** | ✅ All including torsion | — |
| **HSS Round** | ✅ All including torsion | — |
| **Channels, WT, Angles** | ❌ | Not yet implemented |
| **Plate girders** | ⚠️ Web slenderness only | No tension field action (G3) |

### Design Philosophy

- **LRFD only** — ASD (Ω factors) not implemented
- **US/SI units via Unitful** — Functions work with any consistent units
- **Member-level design** — No system-level checks (diaphragm, stability bracing)
- **Catalog-based optimization** — Sections must be from predefined catalogs

### Units & Input Flexibility

The API accepts **any Unitful quantity** — conversions are automatic:

```julia
using StructuralSizer: kip  # Asap custom unit
# Standard Unitful units (kN, m, ft) available via u"..."

# All equivalent — units converted internally to SI (N, N·m)
size_columns([500u"kN"], [100u"kN*m"], geoms, SteelColumnOptions())
size_columns([112.4kip], [73.76kip*u"ft"], geoms, SteelColumnOptions())
size_columns([500e3], [100.0], geoms, SteelColumnOptions())  # Raw Float64 assumed N, N·m
```

Unit helpers from `Asap` handle the conversion:
- `to_newtons(x)`, `to_newton_meters(x)` — for SI
- `to_kip(x)`, `to_kipft(x)` — for US customary
- Pass-through for `Real` types (assumed correct units)

---

## Supported Section Types

| Type | Module | Description |
|------|--------|-------------|
| `ISymmSection` | `i_symm/` | W-shapes, S-shapes, doubly symmetric I-beams |
| `HSSRectSection` | `hss_rect/` | Rectangular and square HSS/tubes |
| `HSSRoundSection` | `hss_round/` | Round HSS and pipes |

---

## Quick Start

```julia
using StructuralSizer
using Unitful

# Load section from catalog
section = W("W14X22")
material = A992_Steel

# Single capacity checks
ϕPn = get_ϕPn(section, material, 12u"ft"; axis=:weak)      # Compression (Ch. E)
ϕMn = get_ϕMn(section, material; Lb=12u"ft", Cb=1.0)       # Flexure (Ch. F)
ϕVn = get_ϕVn(section, material; axis=:strong)             # Shear (Ch. G)
ϕPn_t = get_ϕPn_tension(section, material)                 # Tension (Ch. D)

# Interaction check (Ch. H)
ratio = check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)
# ratio ≤ 1.0 → OK
```

---

## AISCChecker (Optimization Interface)

For discrete optimization, use `AISCChecker` which caches capacities and checks feasibility efficiently:

```julia
# Create checker with options
checker = AISCChecker(;
    ϕ_b = 0.9,               # Flexure resistance factor
    ϕ_c = 0.9,               # Compression resistance factor
    ϕ_v = 1.0,               # Shear (rolled I-shapes)
    deflection_limit = 1/360, # Optional L/δ limit
    max_depth = 0.6,         # Max section depth [m]
    prefer_penalty = 1.05    # Penalty for non-preferred sections
)

# Setup
catalogue = collect(ISymmSection, W_CATALOGUE)
cache = create_cache(checker, length(catalogue))
precompute_capacities!(checker, cache, catalogue, A992_Steel, MinWeight())

# Define demand (with B1 end moments)
demand = MemberDemand(1;
    Pu_c = 200u"kN",         # Compression
    Mux = 50u"kN*m",         # Strong-axis moment
    M1x = -40u"kN*m",        # Smaller end moment (negative = single curvature)
    M2x = 50u"kN*m",         # Larger end moment
    Vu_strong = 30u"kN",     # Shear
)

# Define geometry
geometry = SteelMemberGeometry(4.0;  # L = 4m
    Lb = 4.0,                # Unbraced length for LTB
    Cb = 1.0,                # Moment gradient factor
    Kx = 1.0,                # Effective length factor (strong)
    Ky = 1.0,                # Effective length factor (weak)
    braced = true            # Frame braced against sidesway
)

# Check feasibility (includes B1 amplification)
feasible = is_feasible(checker, cache, j, section, material, demand, geometry)
```

---

## Chapter Coverage

### Chapter E — Compression

Flexural, torsional, and flexural-torsional buckling with slender element reduction (Q factors).

```julia
# Nominal strength
Pn = get_Pn(section, material, KL; axis=:weak)
Pn = get_Pn(section, material, KL; axis=:strong)
Pn = get_Pn(section, material, KL; axis=:torsional)

# Design strength (LRFD)
ϕPn = get_ϕPn(section, material, KL; axis=:weak, ϕ=0.9)

# Slenderness factors (E7)
factors = get_compression_factors(section, material)
# factors.Qs  — Unstiffened elements (flanges)
# factors.Qa  — Stiffened elements (webs/walls)
# factors.Q   — Combined Q = Qs × Qa
```

**Equations:**
- Fe: Euler buckling (E3-4, E4-4)
- Fcr: Critical stress (E3-2/E3-3 or E7-2/E7-3)
- Q factors: Table B4.1a limits, E7 effective width

### Chapter F — Flexure

Yielding, lateral-torsional buckling (LTB), and flange local buckling (FLB).

```julia
# Nominal strength
Mn = get_Mn(section, material; Lb=Lb, Cb=1.0, axis=:strong)
Mn = get_Mn(section, material; axis=:weak)

# Design strength (LRFD)
ϕMn = get_ϕMn(section, material; Lb=Lb, Cb=1.2, axis=:strong, ϕ=0.9)

# LTB limits
ltb = get_Lp_Lr(section, material)
# ltb.Lp — Limiting length for yielding
# ltb.Lr — Limiting length for inelastic LTB
```

**Equations:**
- Lp, Lr: F2-5, F2-6
- Fcr (LTB): F2-4
- FLB: F3-1, F3-2 (strong axis), F6-2, F6-3 (weak axis)

### Chapter G — Shear

Web shear buckling with Cv coefficients.

```julia
# Nominal strength
Vn = get_Vn(section, material; axis=:strong, kv=5.34, rolled=true)

# Design strength (ϕ=1.0 for most rolled I-shapes)
ϕVn = get_ϕVn(section, material; axis=:strong)
```

**Equations:**
- Vn = 0.6 Fy Aw Cv1 where Aw = d × tw (G2-1, full-depth web area)
- Cv1, Cv2: G2.1, G4, G5
- Round HSS shear buckling: G5-2a, G5-2b (with Lv)

### Chapter D — Tension

Gross section yielding and net section rupture.

```julia
# Design strength (min of yielding and rupture)
ϕPn = get_ϕPn_tension(section, material; Ae_ratio=0.75)
```

### Chapter H — Combined Forces

P-M interaction equations for beam-columns.

```julia
# Uniaxial P-M (H1-1)
ratio = check_PM_interaction(Pu, Mu, ϕPn, ϕMn)

# Biaxial P-Mx-My (H1-2)
ratio = check_PMxMy_interaction(Pu, Mux, Muy, ϕPn, ϕMnx, ϕMny)
# ratio ≤ 1.0 → Adequate
# ratio > 1.0 → Overstressed
```

**Equations:**
- Pr/Pc ≥ 0.2: Pr/Pc + 8/9(Mrx/Mcx + Mry/Mcy) ≤ 1.0
- Pr/Pc < 0.2: Pr/(2Pc) + Mrx/Mcx + Mry/Mcy ≤ 1.0

### Chapter H3 — Torsion (HSS)

Torsional strength and combined interaction for HSS sections.

```julia
# Torsional strength
Tn = get_Tn(section, material)           # Nominal
ϕTn = get_ϕTn(section, material; ϕ=0.9)  # Design

# Critical stress
Fcr = get_Fcr_torsion(section, material)

# Torsional constant
C = torsional_constant_rect_hss(B, H, t)
C = torsional_constant_round_hss(D, t)

# Combined interaction (H3-6)
ratio = check_combined_torsion_interaction(Pr, Mr, Vr, Tr, Pc, Mc, Vc, Tc)

# Can torsion be neglected? (H3.2: Tr ≤ 0.2Tc)
can_neglect_torsion(Tr, Tc)
```

### Chapter I — Composite Members (Beams)

Composite slab-on-beam design with full and partial composite action.

```julia
using StructuralSizer

section = W("W21X55")
material = A992_Steel

# Define slab (solid slab, 7.5 in. thick, 4 ksi concrete)
slab = SolidSlabOnBeam(
    7.5u"inch", 4.0u"ksi", 3644.0u"ksi", 145.0u"lb/ft^3", 29000.0u"ksi",
    10.0u"ft", 10.0u"ft"  # beam spacing left/right
)

# Headed stud anchor (¾ in. × 5 in., Fu = 65 ksi)
anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0u"ksi", 50.0u"ksi", 7850.0u"kg/m^3")

# Effective width (I3.1a)
b_eff = get_b_eff(slab, 45.0u"ft")

# Stud strength (I8.2a)
Qn = get_Qn(anchor, slab)

# Composite moment capacity (I3.2a, plastic stress distribution)
ΣQn = 40 * Qn   # 40 studs per half-span
result = get_ϕMn_composite(section, material, slab, b_eff, ΣQn)
# result.ϕMn, result.Mn, result.y_pna, result.Cf, result.a

# Partial composite: find minimum ΣQn for a factored moment demand
req = find_required_ΣQn(section, material, slab, b_eff, 500.0u"kip*ft", Qn)
# req.ΣQn, req.n_studs_half, req.sufficient

# Negative moment (I3.2b) with slab rebar
Mn_neg = get_Mn_negative(section, material, 2.0u"inch^2", 60.0u"ksi")

# Deflection check (shored vs unshored)
defl = check_composite_deflection(section, material, slab, b_eff, ΣQn,
    45.0u"ft", 0.5u"kip/ft", 0.8u"kip/ft"; shored=false)
# defl.δ_DL, defl.δ_LL, defl.ok_LL

# Construction-stage check (bare steel, I3.1b)
const_check = check_construction(section, material, 200.0u"kip*ft", 50.0u"kip";
    Lb_const=45.0u"ft")
# const_check.flexure_ok, const_check.shear_ok
```

**Key types:**
- `SolidSlabOnBeam` / `DeckSlabOnBeam`: Slab-on-beam configurations (solid and metal deck)
- `HeadedStudAnchor`: Stud properties, including `n_per_row` for multi-row layouts
- `CompositeContext`: Bundles slab + anchor + geometry for the checker pipeline

**Equations:**
- Effective width: I3.1a (L/8, spacing/2, edge distance)
- Qn: I8.2a (Eq. I8-1), with Rg/Rp per User Note table
- Cf: I3.2d (min of concrete, steel, studs — Eqs. I3-1a/b/c)
- Mn: Plastic stress distribution (I3.2a(a)), continuous PNA solver
- Negative Mn: I3.2b with Asr × Fysr
- I_transformed / I_LB: Commentary I3.2, AISC Manual Eq. C-I3-1 (Y2 method)

### Appendix 8 — Second-Order Analysis (B1/B2)

Moment amplification for P-δ and P-Δ effects.

```julia
# B1: Member curvature (P-δ)
Cm = compute_Cm(M1, M2; transverse_loading=false)
Pe1 = compute_Pe1(E, I, Lc1)
B1 = compute_B1(Pr, Pe1, Cm; α=1.0)  # α=1.0 LRFD, α=1.6 ASD

# B2: Story drift (P-Δ) — requires story-level data
story = B2StoryProperties(
    Pstory,    # Total vertical load on story [kip or N]
    H,         # Story shear used to compute drift [kip or N]
    L,         # Story height [in or mm]
    ΔH;        # First-order inter-story drift [in or mm]
    Pmf = 0.0, # Total load in moment frame columns (optional)
    α = 1.0    # 1.0 for LRFD, 1.6 for ASD
)
# story.RM       — RM factor (from Pmf/Pstory)
# story.Pe_story — Elastic critical buckling strength
# story.B2       — Computed B2 multiplier

# Or compute individually:
RM = compute_RM(Pmf, Pstory)
Pe_story = compute_Pe_story(H, L, ΔH, RM)
B2 = compute_B2(Pstory, Pe_story; α=1.0)

# Amplified demands (A-8-1, A-8-2)
Mr = amplify_moments(Mnt, Mlt, B1, B2)
Pr = amplify_axial(Pnt, Plt, B2)
```

**Note:** B1 is automatically applied in `AISCChecker.is_feasible()` when `Pu_c > 0`. B2 requires story-level data (`B2StoryProperties`) and should be applied externally for sway frames.

---

## Slenderness Classification

Per Table B4.1:

```julia
sl = get_slenderness(section, material)
# sl.λ_f, sl.λ_w     — Flange/web slenderness ratios
# sl.λp_f, sl.λr_f   — Compact/noncompact limits (flange)
# sl.λp_w, sl.λr_w   — Compact/noncompact limits (web)
# sl.class_f         — :compact, :noncompact, or :slender
# sl.class_w         — :compact, :noncompact, or :slender

# Compression limits (Table B4.1a)
lim = get_compression_limits(section, material)
# lim.λ_f, lim.λ_w, lim.λr
```

---

## File Structure

```
aisc/
├── _aisc.jl              # Module aggregation
├── checker.jl            # AISCChecker (optimization interface)
├── utils.jl              # Euler buckling, column curve helpers
├── generic/
│   ├── tension.jl        # Chapter D
│   ├── interaction.jl    # Chapter H (P-M interaction)
│   └── moment_amplification.jl  # Appendix 8 (B1/B2)
├── i_symm/
│   ├── compression.jl    # Chapter E (W-shapes)
│   ├── flexure.jl        # Chapter F
│   ├── shear.jl          # Chapter G
│   └── slenderness.jl    # Table B4.1
├── hss_rect/
│   ├── compression.jl    # E + E7 effective width
│   ├── flexure.jl        # F7 + F7 effective width
│   ├── shear.jl          # G4
│   ├── slenderness.jl    # Table B4.1a
│   └── torsion.jl        # H3.1(b)
├── hss_round/
│   ├── compression.jl    # E + E7
│   ├── flexure.jl        # F8
│   ├── shear.jl          # G5 (with Lv buckling)
│   ├── slenderness.jl    # Table B4.1a
│   └── torsion.jl        # H3.1(a)
├── composite/
│   ├── _composite.jl     # Module aggregation
│   ├── types.jl          # SolidSlabOnBeam, DeckSlabOnBeam, HeadedStudAnchor, CompositeContext
│   ├── effective_width.jl # I3.1a — b_eff
│   ├── stud_strength.jl  # I8.2a — Qn, Rg/Rp, validations
│   ├── flexure.jl        # I3.2 — Cf, PNA solver, Mn, partial composite, negative moment
│   ├── construction.jl   # I3.1b — construction-stage bare steel check
│   ├── deflection.jl     # Commentary I3.2 — I_transformed, I_LB, deflection
│   └── rebar_from_slab.jl # Extract Asr/Fysr from slab results for negative moment
└── reference/            # AISC 360-16 extracts
```

---

## API Summary

### Capacity Functions

| Function | Chapter | Description |
|----------|---------|-------------|
| `get_Pn`, `get_ϕPn` | E | Compression capacity |
| `get_Mn`, `get_ϕMn` | F | Flexural capacity |
| `get_Vn`, `get_ϕVn` | G | Shear capacity |
| `get_ϕPn_tension` | D | Tension capacity |
| `get_Tn`, `get_ϕTn` | H3 | Torsional capacity (HSS) |
| `get_Mn_composite`, `get_ϕMn_composite` | I3.2a | Composite positive flexural strength |
| `get_Mn_negative` | I3.2b | Composite negative flexural strength |
| `get_Cf` | I3.2d | Horizontal shear (compression force) |
| `get_Qn` | I8.2a | Stud nominal shear strength |
| `get_b_eff` | I3.1a | Effective slab width |
| `get_I_transformed`, `get_I_LB` | Commentary I3.2 | Composite / lower-bound moment of inertia |
| `check_composite_deflection` | I3 | Shored / unshored deflection |
| `check_construction` | I3.1b | Construction-stage bare steel check |
| `find_required_ΣQn` | I3.2d | Partial composite solver (binary search) |
| `validate_stud_diameter` | I8.1 | Stud d_sa ≤ 2.5tf check |
| `validate_stud_length` | I8.2 | Stud l_sa ≥ 4d_sa and cover check |
| `check_stud_spacing` | I8.2d | Min/max longitudinal spacing |
| `stud_mass` | — | Single stud mass (for ECC/weight objectives) |
| `composite_stud_contribution` | — | Total stud cost contribution to objective |
| `extract_parallel_Asr` | I3.2b | Extract parallel slab rebar for negative moment |
| `beam_direction_from_vectors` | — | Check if rebar is parallel to beam direction |
| `report_composite_beam` | — | Full composite beam design check report (`test/report_generators/`) |

### Interaction Functions

| Function | Chapter | Description |
|----------|---------|-------------|
| `check_PM_interaction` | H1-1 | Uniaxial P-M check |
| `check_PMxMy_interaction` | H1-2 | Biaxial P-Mx-My check |
| `check_combined_torsion_interaction` | H3-6 | HSS with torsion |

### B1/B2 Functions

| Function | Equation | Description |
|----------|----------|-------------|
| `compute_Cm` | A-8-4 | Equivalent uniform moment factor |
| `compute_Pe1` | A-8-5 | Elastic buckling strength (member) |
| `compute_B1` | A-8-3 | P-δ amplification factor |
| `B2StoryProperties(...)` | — | Story data container (computes RM, Pe_story, B2) |
| `compute_RM` | A-8-8 | RM factor for moment frames |
| `compute_Pe_story` | A-8-7 | Elastic buckling strength (story) |
| `compute_B2` | A-8-6 | P-Δ amplification factor |
| `amplify_moments` | A-8-1 | Mr = B1·Mnt + B2·Mlt |
| `amplify_axial` | A-8-2 | Pr = Pnt + B2·Plt |

### Checker Interface

| Function | Description |
|----------|-------------|
| `AISCChecker()` | Create checker with options |
| `create_cache(checker, n)` | Create capacity cache |
| `precompute_capacities!(...)` | Precompute length-independent values |
| `is_feasible(...)` | Check if section meets demand (with B1) |

---

## Units

All functions accept Unitful quantities. Capacities return in consistent units with input.

```julia
# US Customary
ϕPn = get_ϕPn(section, material, 12u"ft")  # Returns in N (or convert)
uconvert(kip, ϕPn)  # Convert to kips (kip imported from StructuralSizer)

# SI
ϕMn = get_ϕMn(section, material; Lb=3.6u"m")  # Returns in N·m
```

---

## References

- AISC 360-16: Specification for Structural Steel Buildings
- AISC Steel Construction Manual, 15th Edition
- AISC Design Examples, Version 15.0
