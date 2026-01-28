---
name: CIP Flat Plate EFM Design
overview: Implement ACI 318-compliant CIP flat plate design using EFM in ASAP, with a novel tributary-polygon-based generalization for column/middle strip definitions that handles irregular bay geometries while reducing to standard ACI formulas for rectangular panels.
---

# CIP Flat Plate Design with Generalized Strip Definitions

This plan implements flat plate concrete floor design following ACI 318-14/19, using your existing tributary polygon algorithm to generalize strip definitions for irregular bay shapes.

---

## Reference Documents

### Primary Methodology: StructurePoint Design Examples (ACI 318-14)

- [DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf](https://structurepoint.org/publication/pdf/DE-Two-Way-Flat-Plate-Concrete-Floor-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf)
- [DE-Two-Way-Flat-Slab-Concrete-Floor-with-Drop-Panels](https://structurepoint.org/publication/pdf/DE-Two-Way-Flat-Slab-Concrete-Floor-with-Drop-Panels-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf)
- [DE-Two-Way-Concrete-Floor-Slab-with-Beams](https://structurepoint.org/publication/pdf/DE-Two-Way-Concrete-Floor-Slab-with-Beams-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf)
- [DE-Two-Way-Joist-Concrete-Slab-Floor-Waffle-Slab](https://structurepoint.org/publication/pdf/DE-Two-Way-Joist-Concrete-Slab-Floor-Waffle-Slab-System-Analysis-and-Design-ACI-318-14-spSlab-v1000.pdf)

**Use for**: Full DDM and EFM methodology, moment distribution tables (ACI 8.10.4.2, 8.10.5, 8.10.6, 8.10.7), deflection calculations, punching shear details, design validation examples.

### Implementation Equations: Supplementary Document (ACI 318-19)

- Broyles, Solnosky, Brown (2024) - "Structural Methodologies and Equations"

**Use for**: Computation-ready equation forms for As calculation, β₁ formula, Ie calculation, punching shear equations. Note: Uses simplified M-DDM coefficients (Table S-1) which differ slightly from full ACI tables.

### Key Differences Between Sources

| Aspect | StructurePoint (ACI 318-14) | Supplementary Doc (ACI 318-19) |
|--------|----------------------------|--------------------------------|
| Moment distribution | Full ACI tables 8.10.4.2, 8.10.5-7 with l2/l1 ratios | Simplified M-DDM coefficients (fixed values) |
| EFM coverage | Complete treatment with Kec, Kt calculations | Not covered (DDM only) |
| Deflection | Full Ie calculation with multiple load cases | Condensed equations |
| Code provisions | Older but comprehensive examples | Newer code, equation-focused |

**Recommendation**: Follow StructurePoint methodology, use Supplementary Document equations where computation-friendly.

---

## Phase 0: Member Type Hierarchy Refactor

Before implementing flat plate design, refactor the member system to support columns properly.

### Current State

```julia
# Single Member type for everything
mutable struct Member{T}
    segment_indices::Vector{Int}
    L::T; Lb::T; Kx::Float64; Ky::Float64; Cb::Float64
    group_id::Union{UInt64, Nothing}
    section::Union{AbstractSection, Nothing}
    volumes::MaterialVolumes
end
```

### New Type Hierarchy

```julia
abstract type AbstractMember{T} end

# Shared fields (composition over inheritance)
@kwdef mutable struct MemberBase{T}
    segment_indices::Vector{Int}
    L::T
    Lb::T
    Kx::Float64 = 1.0
    Ky::Float64 = 1.0
    Cb::Float64 = 1.0
    group_id::Union{UInt64, Nothing} = nothing
    section::Union{AbstractSection, Nothing} = nothing
    volumes::MaterialVolumes = MaterialVolumes()
end

"""Horizontal member (gravity system)."""
mutable struct Beam{T} <: AbstractMember{T}
    base::MemberBase{T}
    tributary_width::Union{T, Nothing}
end

"""Vertical member (columns)."""
mutable struct Column{T, A} <: AbstractMember{T}
    base::MemberBase{T}
    vertex_idx::Int          # Which skeleton vertex (column location)
    c1::T                    # Cross-section width (direction 1)
    c2::T                    # Cross-section width (direction 2)
    tributary_area::A        # From Voronoi (for initial sizing, foundation loads)
    story::Int
    position::Symbol         # :interior, :edge, :corner
end

"""Diagonal member (lateral system)."""
mutable struct Strut{T} <: AbstractMember{T}
    base::MemberBase{T}
    brace_type::Symbol       # :tension_only, :compression_only, :both
end
```

### Column Dimensions Helper

```julia
# Material-independent: get column footprint from section
function column_dimensions(section::SteelWSection)
    (section.bf, section.d)
end

function column_dimensions(section::SteelHSSSection)
    (section.B, section.H)
end

function column_dimensions(section::ConcreteRectSection)
    (section.b, section.h)
end

function column_dimensions(col::Column)
    isnothing(col.c1) ? column_dimensions(col.base.section) : (col.c1, col.c2)
end
```

### Files to Modify

| File | Changes |
|------|---------|
| `StructuralSynthesizer/src/types.jl` | Add AbstractMember, Beam, Column, Strut |
| `StructuralSynthesizer/src/types.jl` | Update BuildingStructure fields |
| `StructuralSizer/src/members/_members.jl` | Add column_dimensions() |
| `StructuralSynthesizer/src/analyze/members/utils.jl` | Update to use AbstractMember |
| `StructuralSynthesizer/src/core/utils_asap.jl` | Update element creation |

---

## Design Workflow: Geometry → Slab Sizing → Column Sizing

The flat plate design follows a **one-pass workflow** with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE 0: GEOMETRY                                                      │
│  ├── Skeleton vertices = column locations                               │
│  ├── Voronoi vertex tributaries (At for each column)                    │
│  ├── Edge tributaries (straight skeleton - for strip geometry)          │
│  └── Initial column estimate (from span table or Voronoi At)            │
├─────────────────────────────────────────────────────────────────────────┤
│  PHASE 1: SLAB SIZING (uses initial column estimates)                   │
│  ├── Slab thickness h = ln/33 (ln uses initial col_width)               │
│  ├── Build EFM model in ASAP (slab-beam elements)                       │
│  ├── Solve → strip moments + column reactions                           │
│  ├── Design strip reinforcement                                         │
│  ├── Check punching shear (using initial col_width)                     │
│  └── Check deflection                                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  PHASE 2: COLUMN SIZING (uses ASAP reactions)                           │
│  ├── Extract Pu, Mu from ASAP node reactions                            │
│  ├── Feed into StructuralSizer member sizing workflow                   │
│  ├── Size columns using standard concrete/steel design                  │
│  └── ⚠️ WARNING if final_col < initial_col → re-run slab design         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why One-Pass is Usually Sufficient

- Initial column estimates (span table) are typically **conservative** (undersized)
- Proper column sizing usually results in **larger** columns
- Larger columns = shorter clear span + more punching capacity = **safe**
- Re-analysis only needed if columns end up **smaller** (rare)

### Voronoi Vertex Tributaries

**Regular Voronoi** (not Centroidal) tessellation of column vertices gives tributary area At:

- Used for initial column estimate (supplementary doc Section 1.4)
- Also useful for foundation design (future)
- Computed from skeleton vertices (no extra geometry needed)
- **Stored on `Column.tributary_area`**

**Why Regular Voronoi (not CVT):**

- Columns are at FIXED positions (architectural/structural constraints)
- Tributary = floor area closest to each column (definition of Voronoi)
- No optimization of column placement needed at this stage

**Clipping:** Voronoi cells must be clipped to the floor polygon boundary.

**Future Enhancement:** Centroidal Voronoi Tessellation (CVT) could optimize column placement by iteratively moving columns to cell centroids for more uniform tributary areas. Out of scope for initial implementation.

### Integrated Tributary Computation

Extend existing `compute_cell_tributaries!()` to compute both edge and vertex tributaries:

```julia
function compute_tributaries!(struc::BuildingStructure; opts)
    # 1. Edge tributaries (existing) → cell.tributary
    for cell in struc.cells
        verts = get_cell_vertices(struc, cell)
        cell.tributary = get_tributary_polygons_isotropic(verts)
    end
    
    # 2. Vertex tributaries (NEW - Regular Voronoi, clipped to floor)
    floor_polygon = get_floor_boundary(struc)
    column_positions = [struc.skeleton.vertices[c.vertex_idx] for c in struc.columns]
    
    vorn = voronoi(triangulate(column_positions))
    for (col_idx, cell) in enumerate(get_polygons(vorn))
        clipped = intersect(cell, floor_polygon)  # Clip to boundary
        struc.columns[col_idx].tributary_area = area(clipped)
    end
end
```

### ASAP Reactions for Final Column Loads

After EFM analysis, ASAP gives actual column reactions:

- More accurate than At × qu (accounts for continuity, stiffness)
- Includes moments (Mu) for interaction design
- Feeds directly into existing member sizing workflow

---

## Unit Handling Strategy

**Principle: Internal SI (meters), interface accepts any Unitful quantity.**

```julia
# Constants in readable units, converted to SI internally
const H_MIN_FIRE = uconvert(u"m", 5.0u"inch")      # 0.127 m
const CLEAR_COVER = uconvert(u"m", 0.75u"inch")    # 0.019 m

# Functions accept any units, convert at boundary
function min_thickness(ln; fy=60u"ksi")
    ln_m = uconvert(u"m", ln)
    h_m = ln_m / 33
    return max(h_m, H_MIN_FIRE)  # Returns meters
end
```

**Why meters internally:**

1. ASAP uses SI (meters, Pascals, kg/m³)
2. Avoids unit conversion errors mid-calculation
3. No repeated conversions in hot loops

**User-facing:** Results can be displayed in preferred units via `uconvert()`.

---

## Thickness Optimization (Binary Search)

Find minimum feasible h with configurable precision:

```julia
function optimize_slab_thickness(
    struc, material, loads;
    precision = 0.5u"inch",   # Search resolution
    h_min = 5.0u"inch",       # Fire rating minimum
    h_max = nothing           # Defaults to ln/33
)
    prec_m = uconvert(u"m", precision)
    h_lo = uconvert(u"m", h_min)
    h_hi = isnothing(h_max) ? initial_thickness_estimate(struc) : uconvert(u"m", h_max)
    
    while (h_hi - h_lo) > prec_m
        h_mid = (h_lo + h_hi) / 2
        if all_checks_pass(struc, h_mid, material, loads)
            h_hi = h_mid  # Can go thinner
        else
            h_lo = h_mid  # Need thicker
        end
    end
    
    # Round UP to precision for safety
    return ceil(h_hi / prec_m) * prec_m
end
```

---

## Grouped Computation Strategy

### Grouping Levels

```
┌─────────────────────────────────────────────────────────────────────────┐
│  CellGroup (geometry hash)                                              │
│  ├── Cells with identical shapes (rotation-invariant)                   │
│  ├── Compute ONCE: edge tributaries, vertex tributaries, strip geometry │
│  └── Distribute to: cells (tributaries), columns (vertex tribs)         │
├─────────────────────────────────────────────────────────────────────────┤
│  Slab (one or more cells)                                               │
│  ├── Physical slab covering multiple bays                               │
│  ├── ONE thickness h for entire slab (governed by worst-case cell)      │
│  └── Governing spans, moments, reinforcement computed at slab level     │
├─────────────────────────────────────────────────────────────────────────┤
│  SlabGroup (design group_id)                                            │
│  ├── Slabs with identical design parameters                             │
│  ├── Compute ONCE: h, reinforcement, checks                             │
│  └── Distribute results to all slabs in group                           │
├─────────────────────────────────────────────────────────────────────────┤
│  Story (optional unification)                                           │
│  └── Unify: max(h) across all slabs on story                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### Multi-Cell Slab Handling

A Slab can span multiple cells (bays). Design is at SLAB level, not cell level:

```julia
# Slab covers cells [A, B, C, D] with different spans
slab.cell_indices = [1, 2, 3, 4]

# Governing values across all cells
spans_gov = governing_spans([cell.spans for cell in slab_cells])
ln_gov = spans_gov.primary - col_width  # Worst-case clear span

# ONE thickness for entire slab
h = optimize_slab_thickness(slab, ln_gov, ...)  # Uses governing ln

# Reinforcement designed for governing moments
M0 = qu * l2 * ln_gov^2 / 8  # Uses governing ln
As = design_reinforcement(M0, h, ...)

# Result applies to ALL cells in slab
slab.result = FlatPlateResult(h, As, ...)
```

### Full Workflow

```julia
function size_flat_plates!(struc; opts)
    # ═══════════════════════════════════════════════════════════════════
    # PHASE 1: Geometry (per CellGroup)
    # ═══════════════════════════════════════════════════════════════════
    build_cell_groups!(struc)
    
    for (hash, cell_group) in struc.cell_groups
        representative = struc.cells[cell_group.cell_indices[1]]
        
        # Compute once for this geometry
        edge_tribs = compute_edge_tributaries(representative)
        vertex_tribs = compute_vertex_tributaries(representative)  # Voronoi
        strips = compute_panel_strips(edge_tribs)
        
        # Distribute to all cells with this geometry
        for c_idx in cell_group.cell_indices
            struc.cells[c_idx].tributary = edge_tribs
            struc.cells[c_idx].strips = strips
        end
        
        # Distribute vertex tribs to columns at these cell vertices
        distribute_vertex_tribs_to_columns!(struc, cell_group, vertex_tribs)
    end
    
    # ═══════════════════════════════════════════════════════════════════
    # PHASE 2: Design (per SlabGroup)
    # ═══════════════════════════════════════════════════════════════════
    build_slab_groups!(struc)
    
    for (gid, slab_group) in struc.slab_groups
        representative = struc.slabs[slab_group.slab_indices[1]]
        
        # Get governing parameters across all cells in representative slab
        slab_cells = [struc.cells[i] for i in representative.cell_indices]
        spans_gov = governing_spans([c.spans for c in slab_cells])
        
        # Size once for this design group
        h = optimize_slab_thickness(representative, spans_gov, ...)
        moments = compute_moments(spans_gov, h)
        reinforcement = design_reinforcement(moments, h)
        
        # Apply to ALL slabs in group
        for s_idx in slab_group.slab_indices
            struc.slabs[s_idx].result = FlatPlateResult(h, reinforcement, ...)
        end
    end
    
    # ═══════════════════════════════════════════════════════════════════
    # PHASE 3: Optional Story Unification
    # ═══════════════════════════════════════════════════════════════════
    if opts.unify_by_story
        for (story_idx, story_slabs) in group_slabs_by_story(struc)
            h_max = maximum(s.result.thickness for s in story_slabs)
            for slab in story_slabs
                slab.result = with_thickness(slab.result, h_max)
            end
        end
    end
    
    # ═══════════════════════════════════════════════════════════════════
    # PHASE 4: Column Sizing (after slab finalized)
    # ═══════════════════════════════════════════════════════════════════
    build_efm_model!(struc)  # Uses finalized slab thicknesses
    solve!(struc.asap_model)
    size_columns_from_reactions!(struc)
end
```

### Options

```julia
@kwdef struct FlatPlateOptions
    precision::Unitful.Length = 0.5u"inch"   # Thickness search precision
    unify_by_story::Bool = true               # Max(h) across story
    unify_groups::Vector{Vector{Int}} = []    # Custom slab groupings
end
```

---

## Slab Type Hierarchy (Extensibility)

The workflow is designed to be extensible to all slab types and materials.

### Structural Behavior Types (Material-Agnostic)

```julia
abstract type AbstractSlabType end

# ═══════════════════════════════════════════════════════════════════════════
# Beamless slabs (αf = 0) - slab spans directly to columns
# ═══════════════════════════════════════════════════════════════════════════
abstract type BeamlessSlabType <: AbstractSlabType end

struct FlatPlate <: BeamlessSlabType end      # Uniform thickness ← CURRENT FOCUS
struct FlatSlab <: BeamlessSlabType           # +drop panels
    drop_panel::DropPanelSpec
end
struct OneWay <: BeamlessSlabType end         # One-way spanning

@kwdef struct DropPanelSpec
    width::Unitful.Length    # Typically l/3
    depth::Unitful.Length    # Additional depth below slab soffit
end

# ═══════════════════════════════════════════════════════════════════════════
# Beamed slabs (αf > 0) - beams on column lines
# ═══════════════════════════════════════════════════════════════════════════
abstract type BeamedSlabType <: AbstractSlabType end

struct TwoWayBeamed <: BeamedSlabType end     # Solid slab with beams
struct WaffleSlab <: BeamedSlabType           # Two-way joist (ribbed)
    rib_spacing::Unitful.Length
    rib_width::Unitful.Length
    void_depth::Unitful.Length
end
```

### Material Types

```julia
abstract type SlabMaterial end

# ═══════════════════════════════════════════════════════════════════════════
# Concrete Materials (ACI 318)
# ═══════════════════════════════════════════════════════════════════════════
abstract type ConcreteMaterial <: SlabMaterial end
struct NormalWeightConcrete <: ConcreteMaterial
    fc::Unitful.Pressure
end
struct LightweightConcrete <: ConcreteMaterial
    fc::Unitful.Pressure
    λ::Float64  # Lightweight factor
end

# ═══════════════════════════════════════════════════════════════════════════
# Timber Materials (NDS)
# ═══════════════════════════════════════════════════════════════════════════
abstract type TimberMaterial <: SlabMaterial end
struct CLT <: TimberMaterial                  # Cross-Laminated Timber
    layup::Symbol                             # :3ply, :5ply, :7ply, :9ply
    grade::Symbol                             # :E1, :V2, etc.
    manufacturer::String                      # For panel capacities
end
struct NLT <: TimberMaterial                  # Nail-Laminated Timber
    lumber_size::Symbol                       # :2x6, :2x8, :2x10, :2x12
    species::Symbol                           # :SPF, :DF, :SYP
end
struct GLT <: TimberMaterial                  # Glue-Laminated Timber
    grade::Symbol
    width::Unitful.Length
end
```

### Double Dispatch: Type × Material

```julia
# Sizing dispatches on BOTH slab type AND material
function size_floor(slab_type::AbstractSlabType, span, material::SlabMaterial; kwargs...)

# ═══════════════════════════════════════════════════════════════════════════
# Thickness rules - dispatch on type AND material
# ═══════════════════════════════════════════════════════════════════════════
min_thickness(::FlatPlate, ln, ::ConcreteMaterial) = ln / 33          # ACI 8.3.1.1
min_thickness(::FlatPlate, ln, ::CLT) = lookup_clt_thickness(ln)       # NDS/PRG-320
min_thickness(::OneWay, ln, ::NLT) = lookup_nlt_thickness(ln)          # NDS

# ═══════════════════════════════════════════════════════════════════════════
# Self-weight - material-specific
# ═══════════════════════════════════════════════════════════════════════════
self_weight(h, ::ConcreteMaterial) = h * 150u"pcf"    # ~2400 kg/m³
self_weight(h, ::CLT) = h * 35u"pcf"                  # ~560 kg/m³
self_weight(h, ::NLT) = h * 35u"pcf"

# ═══════════════════════════════════════════════════════════════════════════
# Reinforcement - concrete has rebar, timber doesn't
# ═══════════════════════════════════════════════════════════════════════════
design_reinforcement(M, h, ::ConcreteMaterial) = As_calculation(M, h)
design_reinforcement(M, h, ::TimberMaterial) = nothing  # No rebar!

# ═══════════════════════════════════════════════════════════════════════════
# EFM section properties - different E, different calcs
# ═══════════════════════════════════════════════════════════════════════════
efm_section(width, h, ::ConcreteMaterial) = Section(A, Ec, G, I...)
efm_section(width, h, ::CLT) = Section(A, E_eff_clt, G, I...)  # Effective E

# ═══════════════════════════════════════════════════════════════════════════
# Design code reference
# ═══════════════════════════════════════════════════════════════════════════
design_code(::ConcreteMaterial) = :ACI_318
design_code(::TimberMaterial) = :NDS
```

### Usage Examples

```julia
# Concrete flat plate (current focus)
result = size_floor(FlatPlate(), 24u"ft", NWC_4000; sdl=20u"psf", ll=50u"psf")

# CLT flat plate (same workflow, different material dispatch!)
clt_mat = CLT(:5ply, :E1, "Nordic")
result = size_floor(FlatPlate(), 24u"ft", clt_mat; sdl=20u"psf", ll=50u"psf")

# NLT one-way slab
nlt_mat = NLT(:2x10, :SPF)
result = size_floor(OneWay(), 16u"ft", nlt_mat; sdl=15u"psf", ll=40u"psf")
```

### What's Shared vs Material-Specific

| Component | Shared (all materials) | Material-Specific |
|-----------|------------------------|-------------------|
| Voronoi tributaries | ✅ | |
| Edge tributaries | ✅ | |
| CellGroup/SlabGroup | ✅ | |
| ASAP EFM model | ✅ (structure) | E, G, ρ values |
| Thickness calc | | ✅ (ACI vs NDS) |
| Self-weight | | ✅ (density) |
| Reinforcement design | | ✅ (concrete only) |
| Fire rating | | ✅ (cover vs charring) |
| Column sizing | ✅ (workflow) | Material-specific checks |

### Shared vs Type-Specific Methods

```julia
# ═══════════════════════════════════════════════════════════════════════════
# SHARED across ALL types (inherited from AbstractSlabType)
# ═══════════════════════════════════════════════════════════════════════════
# - Voronoi vertex tributaries
# - Edge tributaries (straight skeleton)
# - CellGroup/SlabGroup caching
# - Binary search thickness optimization
# - ASAP frame integration
# - Column sizing from reactions
# - Reinforcement As calculation

# ═══════════════════════════════════════════════════════════════════════════
# SHARED across BeamlessSlabType (αf = 0)
# ═══════════════════════════════════════════════════════════════════════════
moment_distribution(::BeamlessSlabType, M0, span_type) = MDDM_COEFFICIENTS[span_type]

# ═══════════════════════════════════════════════════════════════════════════
# TYPE-SPECIFIC (dispatch per type)
# ═══════════════════════════════════════════════════════════════════════════

# Minimum thickness (ACI 8.3.1)
min_thickness(::FlatPlate, ln) = ln / 33
min_thickness(::FlatSlab, ln, drop) = ln / 36   # Thinner with drops
min_thickness(::TwoWayBeamed, ln, αf) = ...     # Table 8.3.1.2
min_thickness(::WaffleSlab, ln) = ln / 21

# EFM element sections
efm_section(::FlatPlate, width, h) = slab_beam_section(width, h)
efm_section(::FlatSlab, width, h, drop) = slab_beam_with_drop(width, h, drop)
efm_section(::TwoWayBeamed, beam_section) = beam_section  # Actual beam
efm_section(::WaffleSlab, width, h, ribs) = ribbed_section(width, h, ribs)

# Punching shear perimeter
punching_perimeter(::FlatPlate, c, d) = 4(c + d)
punching_perimeter(::FlatSlab, c, d, drop) = perimeter_with_drop(c, d, drop)

# Self-weight
self_weight(::FlatPlate, h, ρ) = h * ρ
self_weight(::FlatSlab, h, drop, ρ) = ...       # Thicker at drops
self_weight(::WaffleSlab, h, ribs, ρ) = ...     # Accounts for voids

# Moment distribution coefficients
moment_coefficients(::BeamlessSlabType) = MDDM_COEFFICIENTS  # αf = 0
moment_coefficients(::BeamedSlabType, αf, l2_l1) = ...       # ACI Table 8.10.5
```

### Adding a New Slab Type

```julia
# Example: Adding Post-Tensioned Banded Slab
struct PTBanded <: BeamlessSlabType
    tendon_profile::TendonSpec
    band_width::Unitful.Length
end

# Implement 5 required methods:
min_thickness(::PTBanded, ln) = ln / 45  # PT allows thinner
efm_section(::PTBanded, ...) = ...
punching_perimeter(::PTBanded, ...) = ...
self_weight(::PTBanded, ...) = ...
moment_coefficients(::PTBanded) = ...  # Different for PT

# Everything else (tributaries, grouping, ASAP, columns) works automatically!
```

### Full Architecture Diagram

```
SlabDesignSystem
│
├── RCSlabSystem (current - dispatch on material for calcs)
│   │
│   ├── BeamlessSlabType (αf = 0)
│   │   ├── FlatPlate    × {Concrete, CLT}        ← Current focus
│   │   ├── FlatSlab     × {Concrete}
│   │   └── OneWay       × {Concrete, NLT, CLT}
│   │
│   └── BeamedSlabType (αf > 0)
│       ├── TwoWayBeamed × {Concrete}
│       └── WaffleSlab   × {Concrete}
│
├── PTSlabSystem (future - different paradigm)
│   │   Load balancing, stress checks, tendon layout
│   ├── PTBanded
│   └── PTFlatPlate
│
├── CompositeSlabSystem (future)
│   │   Metal deck + concrete, shored/unshored
│   └── MetalDeckComposite
│
└── PrecastSlabSystem (future - selection not design)
    ├── HollowCore
    ├── DoubleTee
    └── MassTimberPanel (catalog selection)
```

### Implementation Priority

| Type | Material | Priority | Notes |
|------|----------|----------|-------|
| FlatPlate | Concrete | P0 | Current focus |
| FlatPlate | CLT | P1 | After concrete works |
| FlatSlab | Concrete | P1 | Add drop panel logic |
| OneWay | NLT | P2 | Simpler timber entry |
| TwoWayBeamed | Concrete | P2 | Real beams, αf > 0 |
| WaffleSlab | Concrete | P3 | Ribbed section |
| PTBanded | Concrete | P4 | Separate design system |

---

## Key Innovation: Tributary-Based Strip Definitions

The ACI strip definitions (column strip = l2/4 from column line) only work for rectangular panels. We generalize using the geometric insight that:

```
Tributary polygon "d" at any point = distance from edge to skeleton ridge
                                   = local "effective span depth"

Column strip = inner half of tributary (from edge to d/2)
Middle strip = total area - column strip areas
```

This **reduces to ACI for rectangles** and **generalizes naturally to irregular shapes**.

---

## Phase 1: Replace cip_aci.jl with Proper Implementation

The current `StructuralSizer/src/slabs/codes/concrete/cip_aci.jl` is conceptually wrong. Replace with a complete implementation based on the StructurePoint methodology:

**New file structure:**

```
StructuralSizer/src/slabs/codes/concrete/
├── _concrete.jl
├── flat_plate/
│   ├── _flat_plate.jl
│   ├── thickness.jl      # ACI 8.3.1.1 min thickness
│   ├── static_moment.jl  # M0 = qu*l*ln²/8
│   ├── strips.jl         # Strip definitions (generalized)
│   ├── moment_dist.jl    # M-DDM moment coefficients (Table S-1)
│   ├── reinforcement.jl  # As calculation
│   ├── punching_shear.jl # Two-way shear check
│   └── deflection.jl     # Ie calculation, deflection limits
├── flat_slab/            # With drop panels (similar structure)
├── two_way_beam/         # Slabs with beams
└── waffle/               # Two-way joist
```

---

## Phase 2: Generalized Strip Geometry

Add new types and functions to `StructuralSizer/src/slabs/tributary/`:

```julia
# New: strips.jl

"""
Split a tributary polygon at half-depth to separate column strip from middle strip.
Returns (column_strip_polygon, middle_strip_polygon, column_strip_area, middle_strip_area)
"""
function split_tributary_at_half_depth(trib::TributaryPolygon)
    # Geometric clipping at d/2
    # Column strip = region from edge to d/2
    # Middle strip = region from d/2 to ridge
    ...
end

"""
Compute strip areas for a panel from its tributary polygons.
"""
struct PanelStripGeometry
    column_strip_areas::Vector{Float64}      # Per-edge contributions
    column_strip_polygons::Vector{Polygon}   # For visualization/checking
    middle_strip_area::Float64
    middle_strip_polygon::Polygon
    total_area::Float64
end

function compute_panel_strips(tributaries::Vector{TributaryPolygon}) -> PanelStripGeometry
    # Sum inner halves for column strip
    # Remainder is middle strip
    ...
end
```

**Verification**: For rectangular panels, confirm that:

- Column strip width = l2/4 on each side of column line
- Middle strip width = l2/2

---

## Phase 3: Moment Distribution

### Option A: Full ACI DDM (from StructurePoint)

Per ACI 318-14 Tables 8.10.4.2, 8.10.5, 8.10.6, 8.10.7 - moment distribution depends on l2/l1 ratio and αf (beam stiffness ratio). The StructurePoint flat plate example shows:

- **Total static moment**: M₀ = (w_u × l₂ × lₙ²) / 8 (ACI 8.10.3.2)
- **Longitudinal distribution**: Interior negative = 0.65 M₀, Positive = 0.35 M₀, etc. (varies by span type)
- **Transverse distribution**: Column strip gets 60-100% depending on l2/l1 and αf

### Option B: Simplified M-DDM (from Supplementary Document)

For initial implementation, use the simplified coefficients (Table S-1):

```julia
# moment_dist.jl

# Simplified M-DDM coefficients (Supplementary Document Table S-1)
# For flat plates without beams (αf = 0)
const MDDM_COEFFICIENTS = (
    end_span = (
        column_strip = (ext_neg=0.27, pos=0.345, int_neg=0.55),
        middle_strip = (ext_neg=0.00, pos=0.235, int_neg=0.18)
    ),
    interior_span = (
        column_strip = (neg=0.535, pos=0.186),
        middle_strip = (neg=0.175, pos=0.124)
    )
)

# Full ACI DDM coefficients (StructurePoint methodology)
# TODO: Implement tables with l2/l1 interpolation
const ACI_DDM_TABLES = ...  # ACI Tables 8.10.5.1, 8.10.5.2, etc.

struct PanelMoments
    M0::Float64                    # Total static moment
    column_strip::NamedTuple       # Distributed moments
    middle_strip::NamedTuple
end

function distribute_moments(M0, span_type::Symbol; method=:mddm) -> PanelMoments
    if method == :mddm
    coeffs = span_type == :end_span ? MDDM_COEFFICIENTS.end_span : MDDM_COEFFICIENTS.interior_span
    else  # :full_aci
        # Interpolate from ACI tables based on l2/l1
        ...
    end
    ...
end
```

**Note**: M-DDM coefficients are conservative simplifications. Full ACI tables should be implemented for production use.

---

## Phase 4: EFM Analysis Path in ASAP

The Equivalent Frame Method (per StructurePoint Section 3.2) models slab strips as beams spanning between columns. This provides more accurate moment distribution than DDM for irregular layouts.

**Key EFM concepts from StructurePoint:**

- **Slab-beam stiffness**: I_s = l₂ × h³/12 (ACI 8.11.2)
- **Equivalent column stiffness**: 1/K_ec = 1/ΣK_c + 1/K_t (ACI 8.11.5)
- **Torsional member stiffness**: K_t = Σ(9E_cs × C) / (l₂(1-c₂/l₂)³) (ACI 8.11.5.2)

Add to `StructuralSynthesizer/src/core/utils_asap.jl`:

```julia
function to_asap!(struc::BuildingStructure; analysis_mode::Symbol=:auto)
    mode = determine_analysis_mode(struc, analysis_mode)
    
    if mode == :beam_frame
        # Existing implementation - tributary loads to beam elements
        return to_asap_beam_frame!(struc)
    elseif mode == :equivalent_frame
        # NEW: Flat plate EFM (per StructurePoint methodology)
        return to_asap_efm!(struc)
    end
end

function to_asap_efm!(struc::BuildingStructure)
    # 1. Create nodes at column locations
    # 2. Create equivalent slab-beam elements along column lines
    #    - I_slab = l₂ × h³/12 (full panel width)
    #    - For generalized geometry: use tributary-derived effective width
    # 3. Create equivalent column elements with K_ec
    # 4. Apply uniform loads q_u to slab-beams
    # 5. Solve frame and extract strip moments
    # 6. Distribute to column/middle strips per ACI 8.10.5-7
    ...
end

# Per StructurePoint Section 3.2.2
function equivalent_column_stiffness(Kc_above, Kc_below, Kt)
    sum_Kc = Kc_above + Kc_below
    return 1.0 / (1.0/sum_Kc + 1.0/Kt)
end

function torsional_stiffness(c2, l2, h, Ecs)
    # C = torsional constant per ACI 8.10.5.2(b)
    x, y = minmax(c2, h)
    C = (1 - 0.63*x/y) * x^3 * y / 3
    return 9 * Ecs * C / (l2 * (1 - c2/l2)^3)
end
```

---

## Phase 5: Reinforcement Design

Per StructurePoint Section 3.1.3 methodology, with computation equations from Supplementary Document Section 1.7:

```julia
# reinforcement.jl

"""
Design strip reinforcement per ACI 318.
Equation form from Supplementary Document (Setareh & Darvas derivation).
Methodology per StructurePoint flat plate example Section 3.1.3.
"""
function design_strip_reinforcement(Mu, strip_width, h, fc, fy; cc=0.75u"inch")
    # Effective depth (ACI 22.2)
    d = h - cc - 0.25u"inch"  # Assuming #4 bars initially
    
    # Resistance coefficient (Supplementary Doc Eq. 1.7)
    Rn = Mu / (0.9 * strip_width * d^2)
    
    # Stress block factor (ACI 22.2.2.4.3)
    β1 = max(0.65, 0.85 - 0.05 * (fc/1000 - 4))  # fc in psi
    
    # Required steel area (Supplementary Doc - derived from ACI 22.2)
    As_reqd = (β1 * fc * strip_width * d / fy) * (1 - sqrt(1 - 2*Rn/(β1*fc)))
    
    # Minimum steel (ACI 8.6.1.1)
    As_min = 0.0018 * strip_width * h
    
    return max(As_reqd, As_min)
end

# Per StructurePoint: select actual bars from available sizes
function select_reinforcement(As_reqd, strip_width)
    # Try each bar size #4 through #10, find minimum mass solution
    # Check spacing limits per ACI 8.7.2.2: s_max = min(2h, 18 in)
    ...
end
```

---

## Phase 6: Complete Checks

### Punching Shear (StructurePoint Section 5, Supplementary Doc Section 1.8)

Per ACI 318-14 Section 22.6.5, punching shear is critical at d/2 from column face.

**Vu source**: Extract from ASAP node reactions after EFM analysis (no need for vertex tributary calculation).

```julia
# punching_shear.jl

"""
Two-way (punching) shear check per ACI 22.6.5.
StructurePoint Section 5 provides detailed methodology.

Vu is obtained from ASAP node reactions at column locations.
"""
function check_punching_shear(Vu, col_width, d, fc; β_c=1.0, αs=40)
    # Critical perimeter at d/2 from column face
    b0 = 4 * (col_width + d)
    
    # Concrete shear strength (ACI 22.6.5.2)
    # Three criteria - take minimum
    Vc1 = 4 * sqrt(fc) * b0 * d                           # ACI Eq. 22.6.5.2a
    Vc2 = (2 + 4/β_c) * sqrt(fc) * b0 * d                 # ACI Eq. 22.6.5.2b
    Vc3 = (2 + αs*d/b0) * sqrt(fc) * b0 * d               # ACI Eq. 22.6.5.2c
    
    Vc = min(Vc1, Vc2, Vc3)
    ϕVc = 0.75 * Vc
    
    # With shear reinforcement (if needed): ϕVn = ϕ(Vc + Vs)
    # Supplementary Doc uses 6√fc assuming shear reinforcement present
    
    return (ϕVc >= Vu, ϕVc, Vu)
end

# Unbalanced moment transfer per ACI 8.4.4.2 (StructurePoint Section 5.2)
function moment_transfer_shear(Mub, col_width, d, fc)
    # γv fraction transferred by shear
    b1 = col_width + d
    b2 = col_width + d
    γf = 1 / (1 + (2/3)*sqrt(b1/b2))
    γv = 1 - γf
    
    # Additional shear stress from unbalanced moment
    ...
end
```

### Deflection (StructurePoint Section 6, Supplementary Doc Section 1.9)

Per ACI 24.2, using effective moment of inertia Ie:

```julia
# deflection.jl  

"""
Deflection check per ACI 24.2.
Full methodology in StructurePoint Section 6.
"""
function check_deflection(panel, loads, reinforcement)
    # Material properties
    Ec = 57000 * sqrt(fc)  # psi
    fr = 7.5 * sqrt(fc)    # Modulus of rupture
    
    # Gross moment of inertia
    Ig = strip_width * h^3 / 12
    
    # Cracking moment
    Mcr = fr * Ig / (h/2)
    
    # Cracked moment of inertia (requires neutral axis calculation)
    # Solve: 0 = b*c²/2 + η*As*c - η*As*d  (Supplementary Doc)
    η = 29_000_000 / Ec  # Modular ratio
    c = solve_neutral_axis(strip_width, d, As, η)
    Icr = strip_width * c^3 / 3 + η * As * (d - c)^2
    
    # Effective moment of inertia (ACI 24.2.3.5)
    Ie = (Mcr/Ma)^3 * Ig + (1 - (Mcr/Ma)^3) * Icr
    Ie = clamp(Ie, Icr, Ig)
    
    # Immediate deflection
    Δi = 5 * w * l^4 / (384 * Ec * Ie)  # Simply supported approximation
    
    # Long-term deflection (ACI 24.2.4)
    ξ = 2.0  # Time-dependent factor for 5+ years
    ρ_prime = 0  # Compression steel ratio (typically 0 for slabs)
    λΔ = ξ / (1 + 50*ρ_prime)
    
    Δ_LT = Δi_DL * λΔ + Δi_LL
    
    # Limits per ACI Table 24.2.2
    Δ_limit = l / 240  # Floor supporting non-structural elements
    
    return (Δ_LT <= Δ_limit, Δ_LT, Δ_limit)
end
```

---

## Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Input                                                                  │
│  ├── Skeleton vertices = column locations                               │
│  └── Loads: SDL, LL                                                     │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 0: Geometry                                                      │
│  ├── Voronoi vertex tributaries                                         │
│  ├── Edge tributaries - straight skeleton                               │
│  ├── Initial column estimate                                            │
│  └── Split edges at d/2 for strips                                      │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 1: Slab Sizing                                                   │
│  ├── ln = l - initial_col_width                                         │
│  ├── h = ln/33, min 5 in                                                │
│  ├── Build ASAP EFM Model                                               │
│  ├── Solve Frame                                                        │
│  ├── Extract Strip Moments                                              │
│  └── Extract Column Reactions                                           │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 1b: Slab Design                                                  │
│  ├── Reinforcement per Strip                                            │
│  ├── Punching Shear Check                                               │
│  ├── Deflection Check                                                   │
│  └── FlatPlateResult                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│  Phase 2: Column Sizing                                                 │
│  ├── Pu, Mu from ASAP                                                   │
│  ├── StructuralSizer member sizing                                      │
│  ├── Sized Columns                                                      │
│  └── ⚠️ WARNING if final < initial → Re-run slab design                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Files to Create/Modify

### Phase 0: Member Hierarchy & Geometry

| File | Action | Purpose |
|------|--------|---------|
| `StructuralSynthesizer/src/types.jl` | **Modify** | Add AbstractMember, Beam, Column, Strut |
| `StructuralSynthesizer/src/analyze/members/utils.jl` | **Modify** | Dispatch on AbstractMember |
| `StructuralSynthesizer/src/core/utils_asap.jl` | **Modify** | Handle member types |
| `StructuralSizer/src/members/_members.jl` | **Modify** | Add column_dimensions() |
| `StructuralSizer/src/slabs/tributary/voronoi.jl` | **Create** | Voronoi vertex tributary algorithm |
| `StructuralSynthesizer/src/analyze/slabs/utils.jl` | **Modify** | Extend compute_tributaries!() for vertex tribs |
| `StructuralSizer/src/slabs/codes/concrete/flat_plate/initial_sizing.jl` | **Create** | Initial column estimate from span |

### Phase 2: Column Sizing

| File | Action | Purpose |
|------|--------|---------|
| `StructuralSynthesizer/src/analyze/members/column_loads.jl` | **Create** | Extract Pu, Mu from ASAP |
| `StructuralSynthesizer/src/analyze/members/utils.jl` | **Modify** | Integration with member sizing |

### Source Files (Flat Plate - Phase 1)

| File | Action | Purpose |
|------|--------|---------|
| `slabs/codes/concrete/cip_aci.jl` | **Delete** | Conceptually wrong |
| `slabs/codes/concrete/flat_plate/_flat_plate.jl` | **Create** | Module entry point |
| `slabs/codes/concrete/flat_plate/thickness.jl` | **Create** | Min h per ACI 8.3.1.1 |
| `slabs/codes/concrete/flat_plate/strips.jl` | **Create** | Generalized strip geometry |
| `slabs/codes/concrete/flat_plate/moment_dist.jl` | **Create** | M-DDM coefficients |
| `slabs/codes/concrete/flat_plate/reinforcement.jl` | **Create** | As design |
| `slabs/codes/concrete/flat_plate/punching_shear.jl` | **Create** | Two-way shear |
| `slabs/codes/concrete/flat_plate/deflection.jl` | **Create** | Serviceability |
| `slabs/tributary/strips.jl` | **Create** | `split_tributary_at_half_depth()` |
| `slabs/types.jl` | **Modify** | Add `FlatPlateResult`, `StripDesign` |
| `StructuralSynthesizer/.../utils_asap.jl` | **Modify** | Add EFM path |

### Test Files (in `StructuralSizer/test/`)

| File | Action | Purpose |
|------|--------|---------|
| `members/test_member_types.jl` | **Create** | Test AbstractMember hierarchy |
| `members/test_column_dimensions.jl` | **Create** | Test column_dimensions() |
| `tributary/test_voronoi.jl` | **Create** | Test Voronoi vertex tributaries |
| `cip/flat_plate/test_initial_column.jl` | **Create** | Test initial column size estimate |
| `cip/flat_plate/test_column_sizing.jl` | **Create** | Test column loads → sizing flow |
| `runtests.jl` | **Modify** | Add includes for new test files |
| `cip/test_cip.jl` | **Replace** | Old tests for wrong implementation |
| `cip/flat_plate/test_structurepoint_example.jl` | **Create** | Full integration test against PDF |
| `cip/flat_plate/test_strips.jl` | **Create** | Strip geometry verification |
| `cip/flat_plate/test_thickness.jl` | **Create** | Min thickness tests |
| `cip/flat_plate/test_moment_distribution.jl` | **Create** | DDM coefficient tests |
| `cip/flat_plate/test_reinforcement.jl` | **Create** | As calculation tests |
| `cip/flat_plate/test_punching_shear.jl` | **Create** | Two-way shear tests |
| `cip/flat_plate/test_deflection.jl` | **Create** | Serviceability tests |
| `tributary/test_strip_split.jl` | **Create** | `split_tributary_at_half_depth()` tests |

---

## Testing Strategy

Tests will be located in `StructuralSizer/test/` following the existing pattern.

### Test File Structure

```
StructuralSizer/test/
├── runtests.jl                      # Add includes for new test files
├── cip/
│   ├── test_cip.jl                  # Existing (to be replaced/updated)
│   └── flat_plate/
│       ├── test_structurepoint_example.jl  # Full validation against PDF
│       ├── test_strips.jl                  # Strip geometry verification
│       ├── test_thickness.jl               # Min thickness calculation
│       ├── test_moment_distribution.jl     # DDM/M-DDM coefficients
│       ├── test_reinforcement.jl           # As calculation
│       ├── test_punching_shear.jl          # Two-way shear
│       └── test_deflection.jl              # Serviceability checks
└── tributary/
    └── test_strip_split.jl          # split_tributary_at_half_depth tests
```

### Test 1: StructurePoint Example Validation (`test_structurepoint_example.jl`)

Reproduce the flat plate example from StructurePoint PDF with known expected values:

```julia
@testset "StructurePoint Flat Plate Example" begin
    # Input data from StructurePoint PDF Section 1
    l1 = 24.0u"ft"           # Span in direction of analysis
    l2 = 20.0u"ft"           # Transverse span
    col_width = 20.0u"inch"  # Square columns
    fc = 4000.0u"psi"        # Slab concrete
    fy = 60000.0u"psi"       # Rebar
    SDL = 20.0u"psf"         # Partition load
    LL = 40.0u"psf"          # Live load
    
    # Expected results from StructurePoint Tables
    @testset "Minimum thickness" begin
        ln = l1 - col_width
        h_min = ln / 33
        @test h_min ≈ 7.27u"inch" atol=0.1u"inch"
        # Actual h = 7.5 in (rounded up)
    end
    
    @testset "Static moment M0" begin
        # M0 = qu * l2 * ln² / 8 (ACI 8.10.3.2)
        # From StructurePoint: M0 = 158.2 kip-ft (interior span)
        # ... verify calculation
    end
    
    @testset "Moment distribution (DDM)" begin
        # Interior span column strip negative: 0.65 * 0.75 * M0 = 77.1 kip-ft
        # Interior span middle strip positive: 0.35 * 0.40 * M0 = 22.1 kip-ft
        # ... verify against StructurePoint Table 5
    end
    
    @testset "Reinforcement" begin
        # From StructurePoint Table 7: interior column strip requires #5 @ 12" o.c.
        # ... verify As calculation matches
    end
    
    @testset "Punching shear" begin
        # From StructurePoint Section 5: ϕVc = 194.5 kips at interior column
        # Vu = 111.5 kips → utilization ≈ 57%
        # ... verify
    end
    
    @testset "Deflection" begin
        # From StructurePoint Table 16-17
        # Column strip exterior span: Δ_total = 0.254 in
        # ... verify Ie calculation
    end
end
```

### Test 2: Strip Geometry Verification (`test_strips.jl`)

```julia
@testset "Generalized Strip Geometry" begin
    @testset "Rectangular panel matches ACI" begin
        # 20ft × 24ft panel
        # Column strip should be l2/4 = 5ft on each side
        # Middle strip should be 20ft - 10ft = 10ft total
        
        vertices = rectangular_polygon(20.0, 24.0)  # meters
        tribs = get_tributary_polygons(vertices)
        strips = compute_panel_strips(tribs)
        
        # Verify areas
        @test strips.total_area ≈ 20.0 * 24.0 atol=0.01
        @test sum(strips.column_strip_areas) ≈ strips.total_area / 2 atol=0.01
        @test strips.middle_strip_area ≈ strips.total_area / 2 atol=0.01
    end
    
    @testset "L-shaped panel - areas conserved" begin
        vertices = l_shaped_polygon(...)
        tribs = get_tributary_polygons(vertices)
        strips = compute_panel_strips(tribs)
        
        total_from_strips = sum(strips.column_strip_areas) + strips.middle_strip_area
        @test total_from_strips ≈ strips.total_area atol=0.01
    end
    
    @testset "split_tributary_at_half_depth" begin
        # Unit test the splitting function
        trib = TributaryPolygon(...)  # Known simple case
        cs, ms = split_tributary_at_half_depth(trib)
        @test cs.area + ms.area ≈ trib.area
        @test cs.area ≈ trib.area / 2 atol=0.01
    end
end
```

### Test 3: Moment Distribution (`test_moment_distribution.jl`)

```julia
@testset "Moment Distribution Coefficients" begin
    @testset "M-DDM simplified coefficients" begin
        # End span: total should sum to 1.0
        end_cs = 0.27 + 0.345 + 0.55
        end_ms = 0.00 + 0.235 + 0.18
        @test end_cs + end_ms ≈ 1.58  # Note: overlapping regions
        
        # Interior span: total should sum to 1.0
        int_cs = 0.535 + 0.186
        int_ms = 0.175 + 0.124
        @test (int_cs + int_ms) * 2 ≈ 2.04  # Two ends + midspan
    end
    
    @testset "Full ACI DDM tables" begin
        # Test interpolation for various l2/l1 ratios
        # Compare against StructurePoint Table 4
    end
end
```

### Test 4: Punching Shear (`test_punching_shear.jl`)

```julia
@testset "Punching Shear" begin
    @testset "Interior column - StructurePoint example" begin
        col_width = 20.0u"inch"
        d = 6.25u"inch"
        fc = 4000.0u"psi"
        At = 480.0u"ft^2"  # Tributary area
        qu = 0.232u"ksf"   # Factored load
        
        Vu = qu * At
        result = check_punching_shear(Vu, col_width, d, fc)
        
        @test result.ϕVc ≈ 194.5u"kip" rtol=0.02
        @test result.Vu ≈ 111.5u"kip" rtol=0.02
        @test result.passes == true
    end
    
    @testset "Edge and corner columns" begin
        # Different b0 perimeters for edge/corner
        # From StructurePoint Section 5
    end
end
```

### Test 5: Deflection (`test_deflection.jl`)

```julia
@testset "Deflection" begin
    @testset "Effective moment of inertia Ie" begin
        # Verify Ie calculation matches StructurePoint Section 6
        # Ie = (Mcr/Ma)³ * Ig + [1 - (Mcr/Ma)³] * Icr
    end
    
    @testset "Long-term deflection" begin
        # ξ = 2.0 for 5+ years
        # λΔ = ξ / (1 + 50ρ')
        # From StructurePoint Table 17: exterior span Δ_total = 0.254 in
    end
end
```

### Test Data Reference

Key values from StructurePoint Flat Plate Example for validation:

| Parameter | Value | Source |
|-----------|-------|--------|
| Panel size | 24' × 20' | Section 1 |
| Slab thickness h | 7.5 in | Section 2.1 |
| Clear span ln | 22.33 ft | Section 3.1.2 |
| M0 (interior) | 158.2 kip-ft | Eq. 8.10.3.2 |
| ϕVc (interior col) | 194.5 kips | Section 5 |
| Vu (interior col) | 111.5 kips | Section 5 |
| Δ_total (ext span) | 0.254 in | Table 17 |

---

## TODO Tracking

### Phase 0: Member Hierarchy ✅ COMPLETE
- [x] `abstract-member`: Create AbstractMember base type with MemberBase shared fields
- [x] `beam-type`: Create Beam subtype with role field (:girder, :beam, :joist, :infill)
- [x] `column-type`: Create Column subtype with c1, c2, vertex_idx, story, position fields
- [x] `strut-type`: Create Strut subtype with brace_type field
- [x] `update-building-structure`: Update BuildingStructure to use beams, columns, struts vectors
- [x] `initialize-members`: Update initialize_members! to classify from skeleton groups
- [x] `column-classification`: Implement classify_column_position() based on graph connectivity
- [ ] `column-dimensions`: Add column_dimensions() helpers for each section type (deferred)

### Phase 0: Geometry ✅ COMPLETE
- [x] `voronoi-tributary`: Implement Voronoi vertex tributaries (regular, clipped to boundary)
  - Located in `StructuralSizer/src/slabs/tributary/voronoi.jl`
  - Uses DelaunayTriangulation.jl with perturbation for degenerate cases
  - Exports: `VertexTributary`, `compute_voronoi_tributaries()`
- [x] `column-trib-storage`: Store tributaries on Column objects
  - `Column.tributary_area::Float64` - total Voronoi area (m²)
  - `Column.tributary_by_slab::Dict{Int, Float64}` - per-cell breakdown (cell_idx → area)
  - Computed in `compute_column_tributaries!(struc)` during `initialize!`
  - Each cell's Voronoi is computed separately and accumulated on columns
  - Visualization: `visualize_vertex_tributaries()`, `visualize_tributaries_combined()`
- [x] `voronoi-column-storage`: Store Voronoi tributary areas on Column objects
  - Computed automatically in `initialize_members!()` via `compute_column_tributaries!()`
  - Stored as `col.tributary_area::Float64` (always in m²)
  - Validated: corner ~20m², edge ~40m², interior ~80m² for 2×2 bay building
- [ ] `initial-column-estimate`: Implement initial column size estimation from span table

### Phase 1: Slab Type Hierarchy
- [ ] `slab-type-hierarchy`: Create AbstractSlabType, BeamlessSlabType, BeamedSlabType

### Phase 1: Replace cip_aci.jl
- [ ] `delete-old-cip`: Delete conceptually wrong cip_aci.jl
- [ ] `strip-split`: Implement split_tributary_at_half_depth() for column/middle strip
- [ ] `panel-strips`: Implement PanelStripGeometry and compute_panel_strips()
- [ ] `verify-rectangular`: Add tests verifying strip areas match ACI for rectangles

### Phase 1: Core Calculations
- [ ] `thickness-calc`: Implement correct ACI 8.3.1.1 thickness (h = ln/33, min 5 in)
- [ ] `static-moment`: Implement M0 = qu*l*ln²/8 calculation
- [ ] `mddm-dist`: Implement moment distribution (M-DDM simplified + full ACI tables)
- [ ] `reinforcement`: Implement strip reinforcement design (As from Rn)
- [ ] `punching-shear`: Implement punching shear check at columns
- [ ] `deflection`: Implement deflection check with Ie calculation

### Phase 1: EFM Integration
- [ ] `efm-asap`: Add EFM analysis path to to_asap!()
- [ ] `result-types`: Add FlatPlateResult and StripDesign types

### Phase 1: Optimization
- [ ] `thickness-optimization`: Implement binary search for optimal h with precision
- [ ] `story-unification`: Implement unify_by_story and unify_groups options
- [ ] `grouped-computation`: Leverage CellGroup for geometry, SlabGroup for design

### Phase 2: Column Sizing
- [ ] `column-loads-extraction`: Extract Pu, Mu from ASAP reactions for column sizing
- [ ] `column-sizing-integration`: Integrate column loads into StructuralSizer workflow
- [ ] `reanalysis-warning`: Implement warning if final column < initial estimate

### Testing
- [x] `test-member-types`: Write test_member_types.jl for AbstractMember hierarchy
- [ ] `test-column-dimensions`: Write test_column_dimensions.jl
- [x] `test-voronoi`: Write test_voronoi.jl for Voronoi vertex tributaries
  - Tests: `StructuralSynthesizer/test/test_voronoi_tributaries.jl`
  - Visualization test: `StructuralSynthesizer/test/test_voronoi_vis.jl`
- [ ] `test-initial-column`: Write test_initial_column.jl for span table estimates
- [ ] `test-strip-split`: Write test_strip_split.jl for split_tributary_at_half_depth()
- [ ] `test-strips`: Write test_strips.jl for rectangular/irregular strip geometry
- [ ] `test-thickness`: Write test_thickness.jl for ACI 8.3.1.1 min thickness
- [ ] `test-thickness-optimization`: Write test for binary search optimization
- [ ] `test-moment-dist`: Write test_moment_distribution.jl for DDM/M-DDM
- [ ] `test-reinforcement`: Write test_reinforcement.jl for As calculation
- [ ] `test-punching-shear`: Write test_punching_shear.jl with StructurePoint values
- [ ] `test-deflection`: Write test_deflection.jl for Ie and long-term deflection
- [ ] `test-column-sizing`: Write test_column_sizing.jl for ASAP loads → sizing
- [ ] `test-structurepoint-full`: Write test_structurepoint_example.jl full integration
- [ ] `update-runtests`: Update runtests.jl includes
- [ ] `structurepoint-validation`: Validate against StructurePoint 24x20 ft example
