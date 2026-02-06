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

| Aspect              | StructurePoint (ACI 318-14)                          | Supplementary Doc (ACI 318-19)               |
| ------------------- | ---------------------------------------------------- | -------------------------------------------- |
| Moment distribution | Full ACI tables 8.10.4.2, 8.10.5-7 with l2/l1 ratios | Simplified M-DDM coefficients (fixed values) |
| EFM coverage        | Complete treatment with Kec, Kt calculations         | Not covered (DDM only)                       |
| Deflection          | Full Ie calculation with multiple load cases         | Condensed equations                          |
| Code provisions     | Older but comprehensive examples                     | Newer code, equation-focused                 |

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

| File                                                   | Changes                                 |
| ------------------------------------------------------ | --------------------------------------- |
| `StructuralSynthesizer/src/types.jl`                 | Add AbstractMember, Beam, Column, Strut |
| `StructuralSynthesizer/src/types.jl`                 | Update BuildingStructure fields         |
| `StructuralSizer/src/members/_members.jl`            | Add column_dimensions()                 |
| `StructuralSynthesizer/src/analyze/members/utils.jl` | Update to use AbstractMember            |
| `StructuralSynthesizer/src/core/utils_asap.jl`       | Update element creation                 |

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

The workflow is designed to be extensible to all slab types and materials using a **traits pattern**.

### Type Hierarchy (Material-Based)

The primary hierarchy is organized by **material** (for self-weight, E, density calculations):

```julia
abstract type AbstractFloorSystem end

# ═══════════════════════════════════════════════════════════════════════════
# Concrete floors (ACI 318)
# ═══════════════════════════════════════════════════════════════════════════
abstract type AbstractConcreteSlab <: AbstractFloorSystem end

struct OneWay <: AbstractConcreteSlab end       # One-way spanning
struct TwoWay <: AbstractConcreteSlab end       # Two-way spanning to beams
struct FlatPlate <: AbstractConcreteSlab end    # Beamless, uniform ← CURRENT FOCUS
struct FlatSlab <: AbstractConcreteSlab end     # Beamless + drop panels
struct Waffle <: AbstractConcreteSlab end       # Two-way joist (ribbed)
struct PTBanded <: AbstractConcreteSlab end     # Post-tensioned banded

# ═══════════════════════════════════════════════════════════════════════════
# Timber floors (NDS)
# ═══════════════════════════════════════════════════════════════════════════
abstract type AbstractTimberFloor <: AbstractFloorSystem end

struct CLT <: AbstractTimberFloor end           # Cross-Laminated Timber
struct DLT <: AbstractTimberFloor end           # Dowel-Laminated Timber
struct NLT <: AbstractTimberFloor end           # Nail-Laminated Timber
struct MassTimberJoist <: AbstractTimberFloor end

# ═══════════════════════════════════════════════════════════════════════════
# Steel floors
# ═══════════════════════════════════════════════════════════════════════════
abstract type AbstractSteelFloor <: AbstractFloorSystem end

struct CompositeDeck <: AbstractSteelFloor end
struct NonCompositeDeck <: AbstractSteelFloor end
struct JoistRoofDeck <: AbstractSteelFloor end
```

### Spanning Behavior Traits (Cross-Cutting)

**Spanning behavior** is handled via traits, allowing cross-material dispatch without multiple inheritance:

```julia
# ═══════════════════════════════════════════════════════════════════════════
# Trait types
# ═══════════════════════════════════════════════════════════════════════════
abstract type SpanningBehavior end
struct OneWaySpanning <: SpanningBehavior end   # Loads → edges ⊥ span
struct TwoWaySpanning <: SpanningBehavior end   # Loads → all edges
struct BeamlessSpanning <: SpanningBehavior end # Loads → columns directly

# ═══════════════════════════════════════════════════════════════════════════
# Trait function: spanning_behavior(ft) → SpanningBehavior
# This is INTRINSIC to the type and cannot be overridden by options
# ═══════════════════════════════════════════════════════════════════════════
spanning_behavior(::OneWay) = OneWaySpanning()
spanning_behavior(::CLT) = OneWaySpanning()
spanning_behavior(::NLT) = OneWaySpanning()
spanning_behavior(::CompositeDeck) = OneWaySpanning()

spanning_behavior(::TwoWay) = TwoWaySpanning()
spanning_behavior(::Waffle) = TwoWaySpanning()
spanning_behavior(::PTBanded) = TwoWaySpanning()

spanning_behavior(::FlatPlate) = BeamlessSpanning()
spanning_behavior(::FlatSlab) = BeamlessSpanning()

# ═══════════════════════════════════════════════════════════════════════════
# Downstream dispatch on traits
# ═══════════════════════════════════════════════════════════════════════════
load_distribution(ft) = load_distribution(spanning_behavior(ft))
load_distribution(::OneWaySpanning) = DISTRIBUTION_ONE_WAY
load_distribution(::TwoWaySpanning) = DISTRIBUTION_TWO_WAY
load_distribution(::BeamlessSpanning) = DISTRIBUTION_POINT

default_tributary_axis(ft, spans) = default_tributary_axis(spanning_behavior(ft), spans)
default_tributary_axis(::OneWaySpanning, spans) = spans.axis   # Directed
default_tributary_axis(::TwoWaySpanning, spans) = nothing      # Isotropic
default_tributary_axis(::BeamlessSpanning, spans) = nothing    # Isotropic

# ═══════════════════════════════════════════════════════════════════════════
# Convenience predicates
# ═══════════════════════════════════════════════════════════════════════════
is_one_way(ft) = spanning_behavior(ft) isa OneWaySpanning
is_two_way(ft) = spanning_behavior(ft) isa TwoWaySpanning
is_beamless(ft) = spanning_behavior(ft) isa BeamlessSpanning
requires_column_tributaries(ft) = is_beamless(ft)
```

### Why Traits?

1. **Cross-cutting concerns**: CLT and OneWay both use `OneWaySpanning`, despite different materials
2. **Extensibility**: Add new types by defining `spanning_behavior(::NewType)` 
3. **No options override**: Spanning behavior is intrinsic, not user-configurable
4. **Future traits**: Can add `AnalysisMethod`, `ReinforcementType`, etc. independently

### How Dispatch Works

The system uses **three levels of dispatch**:

| Level | Dispatches On | Purpose | Example |
|-------|---------------|---------|---------|
| **Material family** | Abstract type (`AbstractConcreteSlab`) | Density, E, design code | `density(::AbstractConcreteSlab) = 150 pcf` |
| **Spanning behavior** | Trait (`BeamlessSpanning`) | Load path, tributary method | `load_distribution(::BeamlessSpanning) = POINT` |
| **Specific type** | Concrete type (`FlatPlate`) | Code-specific rules | `min_thickness(::FlatPlate, ln) = ln/33` |

```julia
# Material is IMPLICIT in the type hierarchy - no separate material argument needed
ft = FlatPlate()

# Material properties come from parent type
ft isa AbstractConcreteSlab  # true → use concrete density, ACI code

# Spanning behavior comes from trait
spanning_behavior(ft)  # BeamlessSpanning() → column tributaries, DDM

# Type-specific rules dispatch directly
min_thickness(ft, ln)  # ACI 8.3.1.1: ln/33 for flat plates specifically
```

### What's Shared vs Type-Specific

| Component            | Shared (AbstractFloorSystem) | Material-Specific (parent type) | Type-Specific |
| -------------------- | ---------------------------- | ------------------------------- | ------------- |
| Edge tributaries     | ✅ straight skeleton          |                                 |               |
| Voronoi tributaries  | ✅ (if beamless trait)        |                                 |               |
| CellGroup/SlabGroup  | ✅                            |                                 |               |
| ASAP frame structure | ✅                            |                                 |               |
| Density/self-weight  |                              | ✅ concrete vs timber           |               |
| Elastic modulus E    |                              | ✅ Ec vs E_clt                  |               |
| Design code          |                              | ✅ ACI vs NDS                   |               |
| Min thickness rule   |                              |                                 | ✅ ln/33 vs ln/36 |
| Punching shear       |                              |                                 | ✅ concrete only |
| Reinforcement design |                              |                                 | ✅ concrete only |

### Shared vs Trait-Dispatched vs Type-Specific Methods

```julia
# ═══════════════════════════════════════════════════════════════════════════
# SHARED across ALL types (dispatch on AbstractFloorSystem)
# ═══════════════════════════════════════════════════════════════════════════
# - Edge tributaries (straight skeleton)
# - CellGroup/SlabGroup caching
# - Binary search thickness optimization
# - ASAP frame integration
# - Column sizing from reactions

# ═══════════════════════════════════════════════════════════════════════════
# TRAIT-DISPATCHED (dispatch on SpanningBehavior)
# ═══════════════════════════════════════════════════════════════════════════

# Load distribution behavior
load_distribution(ft) = load_distribution(spanning_behavior(ft))
load_distribution(::OneWaySpanning) = DISTRIBUTION_ONE_WAY
load_distribution(::TwoWaySpanning) = DISTRIBUTION_TWO_WAY
load_distribution(::BeamlessSpanning) = DISTRIBUTION_POINT

# Tributary calculation method
default_tributary_axis(ft, spans) = default_tributary_axis(spanning_behavior(ft), spans)
default_tributary_axis(::OneWaySpanning, spans) = spans.axis  # Directed
default_tributary_axis(::TwoWaySpanning, spans) = nothing     # Isotropic
default_tributary_axis(::BeamlessSpanning, spans) = nothing   # Isotropic

# Voronoi vertex tributaries (column loads for beamless only)
requires_column_tributaries(ft) = is_beamless(ft)

# Moment distribution (M-DDM for beamless, ACI tables for beamed)
moment_distribution(ft, M0, span_type) = moment_distribution(spanning_behavior(ft), M0, span_type)
moment_distribution(::BeamlessSpanning, M0, span_type) = M0 * MDDM_COEFFICIENTS[span_type]
moment_distribution(::TwoWaySpanning, M0, span_type, αf, l2_l1) = M0 * ACI_TABLE[span_type, αf, l2_l1]

# ═══════════════════════════════════════════════════════════════════════════
# TYPE-SPECIFIC (dispatch per concrete type)
# ═══════════════════════════════════════════════════════════════════════════

# Minimum thickness (ACI 8.3.1)
min_thickness(::FlatPlate, ln) = ln / 33
min_thickness(::FlatSlab, ln, drop) = ln / 36   # Thinner with drops
min_thickness(::TwoWay, ln, αf) = ...           # Table 8.3.1.2
min_thickness(::Waffle, ln) = ln / 21

# EFM element sections
efm_section(::FlatPlate, width, h) = slab_beam_section(width, h)
efm_section(::FlatSlab, width, h, drop) = slab_beam_with_drop(width, h, drop)
efm_section(::TwoWay, beam_section) = beam_section  # Actual beam
efm_section(::Waffle, width, h, ribs) = ribbed_section(width, h, ribs)

# Punching shear perimeter (beamless only)
punching_perimeter(::FlatPlate, c, d) = 4(c + d)
punching_perimeter(::FlatSlab, c, d, drop) = perimeter_with_drop(c, d, drop)

# Self-weight
self_weight(::FlatPlate, h, ρ) = h * ρ
self_weight(::FlatSlab, h, drop, ρ) = ...       # Thicker at drops
self_weight(::Waffle, h, ribs, ρ) = ...         # Accounts for voids
```

### Adding a New Floor Type

```julia
# Example 1: Adding Mass Timber Joist (one-way spanning timber)
struct MassTimberJoist <: AbstractTimberFloor end

# Step 1: Define spanning behavior (one method!)
spanning_behavior(::MassTimberJoist) = OneWaySpanning()

# Now all trait-dispatched methods work automatically:
#   load_distribution(MassTimberJoist()) → DISTRIBUTION_ONE_WAY ✓
#   is_one_way(MassTimberJoist()) → true ✓
#   requires_column_tributaries(MassTimberJoist()) → false ✓

# Step 2: Implement type-specific methods
min_thickness(::MassTimberJoist, span) = span / 20  # NDS rule
self_weight(::MassTimberJoist, d, spacing, ρ) = ...


# Example 2: Adding Voided Slab (two-way spanning concrete)
struct VoidedSlab <: AbstractConcreteSlab
    void_ratio::Float64
end

spanning_behavior(::VoidedSlab) = TwoWaySpanning()

min_thickness(::VoidedSlab, ln) = ln / 30
self_weight(vs::VoidedSlab, h, ρ) = h * ρ * (1 - vs.void_ratio)
```

### Full Architecture Diagram

```
                        AbstractFloorSystem
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
AbstractConcreteSlab   AbstractTimberFloor    AbstractSteelFloor
        │                      │                      │
   ┌────┴────┐            ┌────┴────┐           ┌────┴────┐
   │         │            │         │           │         │
FlatPlate  TwoWay       CLT       NLT      Composite  NonComposite
FlatSlab   Waffle       DLT    MassTimberJoist  JoistRoof
OneWay     PTBanded

═════════════════════════════════════════════════════════════════════

                       SpanningBehavior (Trait)
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
    OneWaySpanning     TwoWaySpanning     BeamlessSpanning
           │                  │                  │
    spanning_behavior()  spanning_behavior()  spanning_behavior()
    returns for:         returns for:         returns for:
    - OneWay             - TwoWay             - FlatPlate
    - CLT, DLT, NLT      - Waffle             - FlatSlab
    - CompositeDeck      - PTBanded
    - HollowCore
    - MassTimberJoist
```

### Method Resolution Example

```julia
ft = FlatPlate()

# Type hierarchy path (for material properties):
#   ft isa FlatPlate <: AbstractConcreteSlab <: AbstractFloorSystem

# Trait path (for spanning behavior):
#   spanning_behavior(ft) → BeamlessSpanning()

# Method calls:
load_distribution(ft)
#   → load_distribution(spanning_behavior(ft))
#   → load_distribution(BeamlessSpanning())
#   → DISTRIBUTION_POINT

requires_column_tributaries(ft)
#   → is_beamless(ft)
#   → spanning_behavior(ft) isa BeamlessSpanning
#   → true

self_weight(ft, h, ρ)
#   → dispatches directly on FlatPlate (type-specific)
#   → h * ρ
```

### Implementation Priority

| Type         | Material | Priority | Notes                  |
| ------------ | -------- | -------- | ---------------------- |
| FlatPlate    | Concrete | P0       | Current focus          |
| FlatPlate    | CLT      | P1       | After concrete works   |
| FlatSlab     | Concrete | P1       | Add drop panel logic   |
| OneWay       | NLT      | P2       | Simpler timber entry   |
| TwoWayBeamed | Concrete | P2       | Real beams, αf > 0    |
| WaffleSlab   | Concrete | P3       | Ribbed section         |
| PTBanded     | Concrete | P4       | Separate design system |

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

## Alternative: Two-Stage Shell Analysis for Slabs with Beams

For slabs supported on beams (not flat plates), we have an alternative analysis approach that leverages ASAP's new shell element capabilities. This provides direct slab moment output (Mx, My, Mxy) for reinforcement design while using the proven tributary polygon workflow for beam forces.

### Why Two-Stage Analysis?

| Approach | Slab Moments | Beam Forces | Best For |
|----------|--------------|-------------|----------|
| **Full Shell FEM** | ✅ Direct from elements | ⚠️ Extracted from shared nodes (load path unclear) | Research, complex geometries |
| **Pure Tributary** | ❌ Use code coefficients | ✅ Direct control via polygons | Simple rectangular bays |
| **Two-Stage** | ✅ Direct from shell FEM | ✅ Direct control via tributary | Design-oriented workflow |

The two-stage approach gives us the best of both worlds:
- **Stage 1**: Shell analysis → accurate slab bending moments for reinforcement design
- **Stage 2**: Tributary loads → predictable beam forces for beam reinforcement design

### Two-Stage Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  STAGE 1: SLAB ANALYSIS (Shell FEM)                                     │
│  ├── Create ShellModel with slab panels                                 │
│  ├── Support shell edges (simple support: w=0 only)                     │
│  ├── Apply SurfaceLoad (pressure) to shells                             │
│  ├── Solve → get nodal displacements                                    │
│  └── Extract: Mx, My, Mxy for slab reinforcement design                 │
│              Deflections for serviceability check                       │
├─────────────────────────────────────────────────────────────────────────┤
│  STAGE 2: FRAME ANALYSIS (Tributary Loads)                              │
│  ├── Compute tributary polygons from slab geometry                      │
│  ├── Create TributaryLoads for each beam from polygon depths            │
│  ├── Build FrameModel: beams + columns                                  │
│  ├── Apply TributaryLoads to beams                                      │
│  ├── Solve → get beam forces                                            │
│  └── Extract: Mu, Vu for beam reinforcement design                      │
│              Column reactions for column design                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Functions to Implement

#### 1. `shell_to_tributary_loads()` - Core Helper

**Location:** `external/Asap/src/Loads/shell_loads.jl` (new file)

```julia
"""
    shell_to_tributary_loads(shells, beams, pressure; axis=nothing, direction=(0,0,-1))

Generate TributaryLoads for beams from shell panel geometry.

# Arguments
- `shells::Vector{<:ShellElement}`: Shell panels defining slab regions
- `beams::Vector{<:FrameElement}`: Edge beams to receive loads
- `pressure::QuantityPressure`: Uniform pressure on shells

# Keywords  
- `axis::Union{Nothing, Vector{Float64}}`: Load distribution direction
  - `nothing` → two-way (isotropic straight skeleton)
  - `[1,0]` → one-way along X
- `direction::NTuple{3,Float64}`: Load direction (default gravity)

# Returns
- `Vector{TributaryLoad}`: Loads ready to apply to frame model
"""
function shell_to_tributary_loads(
    shells::Vector{<:ShellElement},
    beams::Vector{<:FrameElement},
    pressure::QuantityPressure;
    axis::Union{Nothing, Vector{Float64}} = nothing,
    direction::NTuple{3, Float64} = (0.0, 0.0, -1.0)
)::Vector{TributaryLoad}
    # Implementation steps:
    # 1. For each shell, extract boundary polygon (vertices from nodes)
    # 2. Call get_tributary_polygons(vertices; axis=axis)
    # 3. For each tributary polygon:
    #    - Match to corresponding beam (by edge geometry)
    #    - Sort positions, convert depths to widths
    #    - Create TributaryLoad
    # 4. Return all loads
end
```

#### 2. `match_beam_to_polygon_edge()` - Edge Matching

```julia
"""
    match_beam_to_polygon_edge(beam, polygon_vertices; tol=1e-6)

Find which edge index of the polygon corresponds to this beam.
Returns edge index (1-based) or nothing if no match.
"""
function match_beam_to_polygon_edge(
    beam::FrameElement,
    polygon_vertices::Vector{<:Point};
    tol::Float64 = 1e-6
)::Union{Int, Nothing}
    # Compare beam endpoint positions to polygon edge vertices
    # Handle both directions (beam may be reversed)
end
```

#### 3. `analyze_slab_system()` - Two-Stage Orchestration

**Location:** `external/Asap/src/Analysis/slab_analysis.jl` (new file)

```julia
"""
    analyze_slab_system(shells, beams, columns, pressure; ...)

Two-stage analysis for slab-on-beam systems.

# Returns
- `SlabSystemResult` containing both shell and frame results
"""
function analyze_slab_system(
    shells::Vector{<:ShellElement},
    beams::Vector{<:FrameElement},
    columns::Vector{<:FrameElement},
    pressure::QuantityPressure;
    axis = nothing,  # tributary direction
    one_way::Bool = false  # use orthotropic shell stiffness
)
    # Stage 1: Shell Analysis
    shell_model = create_shell_model(shells, pressure)
    process!(shell_model)
    solve!(shell_model)
    shell_moments = extract_shell_moments(shell_model)
    shell_deflections = extract_shell_deflections(shell_model)
    
    # Stage 2: Frame Analysis
    trib_loads = shell_to_tributary_loads(shells, beams, pressure; axis=axis)
    frame_model = create_frame_model(beams, columns, trib_loads)
    process!(frame_model)
    solve!(frame_model)
    beam_forces = extract_beam_forces(frame_model)
    column_reactions = extract_column_reactions(frame_model)
    
    return SlabSystemResult(
        shell_moments, shell_deflections, shell_model,
        beam_forces, column_reactions, frame_model,
        trib_loads
    )
end
```

### Result Structure

```julia
struct SlabSystemResult
    # Stage 1: Shell results
    shell_moments::Dict{Symbol, NTuple{3, Float64}}  # panel_id => (Mx, My, Mxy) [Nm/m]
    shell_deflections::Dict{Symbol, Float64}          # panel_id => δ_center [m]
    shell_model::ShellModel
    
    # Stage 2: Frame results  
    beam_internal_forces::Dict{Symbol, ElementInternalForces}  # beam_id => P, V, M
    column_reactions::Dict{Symbol, Vector{Float64}}     # col_id => reactions
    frame_model::FrameModel
    
    # Load distribution used
    tributary_loads::Vector{TributaryLoad}
end
```

### Implementation Challenges & Solutions

#### Challenge 1: Edge Matching (Shell Edge → Beam)

**Problem:** How to match a tributary polygon edge to a beam element?

**Solution:** Compare beam endpoint positions to polygon edge vertices with tolerance.

```julia
function match_beam_to_polygon_edge(beam, vertices; tol=1e-6)
    beam_start = [beam.iNode.x, beam.iNode.y, beam.iNode.z]
    beam_end = [beam.jNode.x, beam.jNode.y, beam.jNode.z]
    
    n = length(vertices)
    for i in 1:n
        v1 = [vertices[i].x, vertices[i].y, vertices[i].z]
        v2 = [vertices[mod1(i+1, n)].x, vertices[mod1(i+1, n)].y, vertices[mod1(i+1, n)].z]
        
        # Check both orientations
        if (norm(beam_start - v1) < tol && norm(beam_end - v2) < tol) ||
           (norm(beam_start - v2) < tol && norm(beam_end - v1) < tol)
            return i
        end
    end
    return nothing
end
```

**Potential Issues:**
- Floating-point tolerance selection (geometry-dependent)
- Beams may be slightly offset from shell edges (eccentricity)
- Shell triangulation may not align perfectly with beam endpoints

#### Challenge 2: Multiple Shells Sharing a Beam (Interior Beams)

**Problem:** Interior beams receive load from two adjacent slab panels.

**Solution:** Accumulate tributary loads from all adjacent shells.

```julia
function shell_to_tributary_loads(shells, beams, pressure; ...)
    loads = Dict{FrameElement, Vector{TributaryLoad}}()
    
    for shell in shells
        vertices = get_shell_boundary(shell)
        tribs = get_tributary_polygons(vertices; axis=axis)
        
        for (edge_idx, trib) in enumerate(tribs)
            beam = find_beam_for_edge(beams, vertices, edge_idx)
            if beam !== nothing
                tload = create_tributary_load(beam, trib, pressure, direction)
                push!(get!(loads, beam, []), tload)
            end
        end
    end
    
    # Combine loads on same beam from multiple shells
    return [combine_tributary_loads(beam, tloads) for (beam, tloads) in loads]
end
```

**Potential Issues:**
- Load direction must be consistent across panels
- Tributary depths should be summed, not averaged
- Need to handle partial overlaps carefully

#### Challenge 3: Shell Triangulation vs Rectangular Panels

**Problem:** `ShellTri3` elements give triangular panels, but tributary algorithm expects polygons (typically quadrilaterals).

**Solutions:**

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| A | 2-4 triangles per panel | Simple, sufficient for moments | Tributary computed per-panel, not per-triangle |
| B | Group triangles by panel ID | Works with arbitrary meshes | Requires panel grouping metadata |
| C | Extract boundary from mesh | Automatic | Complex boundary extraction logic |

**Recommended:** Option A for initial implementation - 2 triangles (diagonal split) or 4 triangles (X-split) per rectangular panel. Store panel ID on each shell element for grouping.

```julia
# Each panel gets an ID; all triangles in panel share it
shell1 = ShellTri3(nodes...; id=:panel_A1)
shell2 = ShellTri3(nodes...; id=:panel_A1)  # Same panel

# Group for tributary computation
function get_panel_boundary(shells, panel_id)
    panel_shells = filter(s -> s.id == panel_id, shells)
    return extract_outer_boundary(panel_shells)
end
```

#### Challenge 4: One-Way vs Two-Way Distribution Control

**Problem:** Need explicit control over load distribution direction for one-way slabs.

**Solution:** Use orthotropic shell properties in Stage 1, and `axis` parameter in Stage 2.

```julia
# One-way slab (spanning along Y)
result = analyze_slab_system(
    shells, beams, columns, pressure;
    axis = [0.0, 1.0],  # Tributary perpendicular to span
    one_way = true       # Use orthotropic shell stiffness
)

# Inside analyze_slab_system:
if one_way
    # Modify shell properties to be very stiff in span direction
    for shell in shells
        shell.E_ratio = 0.01  # E_perp / E_span (hypothetical API)
    end
end
```

**Potential Issues:**
- Orthotropic shell implementation not yet complete
- CLT and other naturally orthotropic materials need material-specific handling
- Direction alignment between shell coords and tributary axis

#### Challenge 5: Shell Boundary Conditions (Edge Support)

**Problem:** How to support shell edges without over-constraining?

**Solution:** "Soft" simple support - constrain only vertical displacement (w=0) along edges, leave rotations free.

```julia
function create_shell_model(shells, pressure)
    nodes = collect_unique_nodes(shells)
    edge_nodes = identify_edge_nodes(shells, nodes)
    
    # Simple support: only w=0
    for node in edge_nodes
        node.support = [false, false, true, false, false, false]  # Only z translation
    end
    
    # Apply surface load
    loads = [SurfaceLoad(shell, pressure) for shell in shells]
    
    return ShellModel(nodes, shells, loads)
end
```

**Potential Issues:**
- Need to identify which nodes are on boundary vs interior
- Continuous slabs over supports need rotation coupling (future enhancement)
- Corner supports may need special handling

#### Challenge 6: Deflection Consistency

**Problem:** Shell deflections and beam deflections are computed separately - are they consistent?

**Analysis:** They serve different purposes:
- **Shell deflection** (Stage 1): Slab deflection for ACI Table 24.2.2 limits
- **Beam deflection** (Stage 2): Beam deflection includes beam section properties

**Solution:** Report both; they're both valid for their respective design checks.

```julia
# Slab serviceability (ACI 24.2.2)
δ_slab = result.shell_deflections[:panel_A1]
@assert δ_slab < L/240  # Floor supporting partitions

# Beam serviceability (separate check)
beam_disp = displacements(result.frame_model, 0.5u"m")
δ_beam = maximum(abs.(beam_disp[1].uglobal[3, :]))
```

### Comparison: Tributary Polygons vs Shell Edge Reactions

For completeness, here's how the two-stage approach compares to directly using shell edge reactions:

| Aspect | Tributary Polygons (Our Approach) | Shell Edge Reactions (Alternative) |
|--------|-----------------------------------|-----------------------------------|
| **Basis** | Geometric (straight skeleton) | Physics (FEM equilibrium) |
| **Load shape** | Trapezoidal (d varies linearly to ridge) | Parabolic-ish (varies with plate stiffness) |
| **One-way control** | `axis` parameter → directed tributary | Orthotropic shell E ratio |
| **Mesh independence** | ✅ Uses polygon geometry | ❌ Depends on mesh along edges |
| **Code compliance** | ✅ Matches ACI tributary assumptions | ⚠️ More accurate but non-standard |
| **Speed** | ✅ O(n) polygon algorithm | ⚠️ Requires shell solve first |
| **Implementation** | ✅ Existing `get_tributary_polygons` | 🔲 Need `extract_edge_reactions` |

**Recommendation:** Use tributary polygons (our approach) for standard design workflows. Shell edge reactions could be added as an advanced option for research or validation.

### Test Plan

```julia
@testset "Two-Stage Slab Analysis" begin
    @testset "shell_to_tributary_loads - Rectangle" begin
        # 4m × 3m shell, 4 edge beams
        # Verify tributary loads match analytical
    end
    
    @testset "Edge Matching" begin
        # Verify correct beam-to-edge matching
        # Test both beam orientations
        # Test floating-point tolerance
    end
    
    @testset "Multiple Panels Sharing Beam" begin
        # 2×2 grid of panels, interior beam receives from both sides
        # Verify load accumulation
    end
    
    @testset "One-Way vs Two-Way" begin
        # Same geometry with axis=[0,1] vs axis=nothing
        # Verify load goes only to perpendicular beams for one-way
    end
    
    @testset "Full Workflow - Square Panel" begin
        # Known solution: square plate, uniform load
        # Compare shell moments to analytical (Navier)
        # Compare beam forces to tributary expectation
        # Verify total load = sum of reactions
    end
end
```

### Files to Create

| File | Action | Purpose |
|------|--------|---------|
| `external/Asap/src/Loads/shell_loads.jl` | **Create** | `shell_to_tributary_loads()`, edge matching |
| `external/Asap/src/Analysis/slab_analysis.jl` | **Create** | `analyze_slab_system()`, `SlabSystemResult` |
| `external/Asap/test/test_two_stage_slab.jl` | **Create** | Tests for two-stage workflow |
| `StructuralSynthesizer/src/design_workflow.jl` | **Modify** | Integrate `design_floor_system()` |

### Estimated Effort

| Component | Estimate |
|-----------|----------|
| `shell_to_tributary_loads()` + edge matching | 2-3 hours |
| `analyze_slab_system()` orchestration | 2-3 hours |
| Tests | 2-3 hours |
| StructuralSynthesizer integration | 2-3 hours |
| **Total** | **8-12 hours** |

---

## Files to Create/Modify

### Phase 0: Member Hierarchy & Geometry

| File                                                                      | Action           | Purpose                                        |
| ------------------------------------------------------------------------- | ---------------- | ---------------------------------------------- |
| `StructuralSynthesizer/src/types.jl`                                    | **Modify** | Add AbstractMember, Beam, Column, Strut        |
| `StructuralSynthesizer/src/analyze/members/utils.jl`                    | **Modify** | Dispatch on AbstractMember                     |
| `StructuralSynthesizer/src/core/utils_asap.jl`                          | **Modify** | Handle member types                            |
| `StructuralSizer/src/members/_members.jl`                               | **Modify** | Add column_dimensions()                        |
| `StructuralSizer/src/slabs/tributary/voronoi.jl`                        | **Create** | Voronoi vertex tributary algorithm             |
| `StructuralSynthesizer/src/analyze/slabs/utils.jl`                      | **Modify** | Extend compute_tributaries!() for vertex tribs |
| `StructuralSizer/src/slabs/codes/concrete/flat_plate/initial_sizing.jl` | **Create** | Initial column estimate from span              |

### Phase 2: Column Sizing

| File                                                          | Action           | Purpose                        |
| ------------------------------------------------------------- | ---------------- | ------------------------------ |
| `StructuralSynthesizer/src/analyze/members/column_loads.jl` | **Create** | Extract Pu, Mu from ASAP       |
| `StructuralSynthesizer/src/analyze/members/utils.jl`        | **Modify** | Integration with member sizing |

### Source Files (Flat Plate - Phase 1)

| File                                                  | Action           | Purpose                                  |
| ----------------------------------------------------- | ---------------- | ---------------------------------------- |
| `slabs/codes/concrete/cip_aci.jl`                   | **Delete** | Conceptually wrong                       |
| `slabs/codes/concrete/flat_plate/_flat_plate.jl`    | **Create** | Module entry point                       |
| `slabs/codes/concrete/flat_plate/thickness.jl`      | **Create** | Min h per ACI 8.3.1.1                    |
| `slabs/codes/concrete/flat_plate/strips.jl`         | **Create** | Generalized strip geometry               |
| `slabs/codes/concrete/flat_plate/moment_dist.jl`    | **Create** | M-DDM coefficients                       |
| `slabs/codes/concrete/flat_plate/reinforcement.jl`  | **Create** | As design                                |
| `slabs/codes/concrete/flat_plate/punching_shear.jl` | **Create** | Two-way shear                            |
| `slabs/codes/concrete/flat_plate/deflection.jl`     | **Create** | Serviceability                           |
| `slabs/tributary/strips.jl`                         | **Create** | `split_tributary_at_half_depth()`      |
| `slabs/types.jl`                                    | **Modify** | Add `FlatPlateResult`, `StripDesign` |
| `StructuralSynthesizer/.../utils_asap.jl`           | **Modify** | Add EFM path                             |

### Test Files (in `StructuralSizer/test/`)

| File                                              | Action            | Purpose                                   |
| ------------------------------------------------- | ----------------- | ----------------------------------------- |
| `members/test_member_types.jl`                  | **Create**  | Test AbstractMember hierarchy             |
| `members/test_column_dimensions.jl`             | **Create**  | Test column_dimensions()                  |
| `tributary/test_voronoi.jl`                     | **Create**  | Test Voronoi vertex tributaries           |
| `cip/flat_plate/test_initial_column.jl`         | **Create**  | Test initial column size estimate         |
| `cip/flat_plate/test_column_sizing.jl`          | **Create**  | Test column loads → sizing flow          |
| `runtests.jl`                                   | **Modify**  | Add includes for new test files           |
| `cip/test_cip.jl`                               | **Replace** | Old tests for wrong implementation        |
| `cip/flat_plate/test_structurepoint_example.jl` | **Create**  | Full integration test against PDF         |
| `cip/flat_plate/test_strips.jl`                 | **Create**  | Strip geometry verification               |
| `cip/flat_plate/test_thickness.jl`              | **Create**  | Min thickness tests                       |
| `cip/flat_plate/test_moment_distribution.jl`    | **Create**  | DDM coefficient tests                     |
| `cip/flat_plate/test_reinforcement.jl`          | **Create**  | As calculation tests                      |
| `cip/flat_plate/test_punching_shear.jl`         | **Create**  | Two-way shear tests                       |
| `cip/flat_plate/test_deflection.jl`             | **Create**  | Serviceability tests                      |
| `tributary/test_strip_split.jl`                 | **Create**  | `split_tributary_at_half_depth()` tests |

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

| Parameter           | Value        | Source        |
| ------------------- | ------------ | ------------- |
| Panel size          | 24' × 20'   | Section 1     |
| Slab thickness h    | 7.5 in       | Section 2.1   |
| Clear span ln       | 22.33 ft     | Section 3.1.2 |
| M0 (interior)       | 158.2 kip-ft | Eq. 8.10.3.2  |
| ϕVc (interior col) | 194.5 kips   | Section 5     |
| Vu (interior col)   | 111.5 kips   | Section 5     |
| Δ_total (ext span) | 0.254 in     | Table 17      |

---

## TODO Tracking

This section tracks implementation progress using a phased approach that handles the
interdependency between slab and column design:

```
GEOMETRY → DDM SIZING → COLUMN SIZING → EFM ANALYSIS → FINAL CHECKS → INTEGRATION
   ✅          ✅            ✅              🔲             🔲            🔲

                                    ↓
                        TWO-STAGE SHELL ANALYSIS (Alt. for slabs with beams)
                                   🔲
```

---

### Foundation: Member Hierarchy & Geometry ✅ COMPLETE

- [X] `abstract-member`: Create AbstractMember base type with MemberBase shared fields
- [X] `beam-type`: Create Beam subtype with role field (:girder, :beam, :joist, :infill)
- [X] `column-type`: Create Column subtype with c1, c2, vertex_idx, story, position fields
- [X] `strut-type`: Create Strut subtype with brace_type field
- [X] `update-building-structure`: Update BuildingStructure to use beams, columns, struts vectors
- [X] `initialize-members`: Update initialize_members! to classify from skeleton groups
- [X] `column-classification`: Implement classify_column_position() based on graph connectivity
- [X] `voronoi-tributary`: Implement Voronoi vertex tributaries (regular, clipped to boundary)
- [X] `column-trib-storage`: Store tributaries in TributaryCache (keyed by behavior/axis)
- [X] `voronoi-visualization`: Voronoi tributary visualization with `color_by=:tributary_vertex`
- [X] `cell-position-classification`: Classify cells as :corner/:edge/:interior
- [X] `slab-position-classification`: Derive slab position from cells
- [X] `shell-elements`: Added ShellElement to ASAP for diaphragm modeling
- [X] `spanning-behavior-trait`: Implemented `SpanningBehavior` trait system

---

### Phase 1: DDM Slab Calculations ✅ COMPLETE

**Location**: `StructuralSizer/src/slabs/codes/concrete/flat_plate/calculations.jl`
**Tests**: `StructuralSizer/test/slabs/test_flat_plate.jl` (validated against StructurePoint)

- [X] `material-props`: `Ec()`, `β1()`, `fr()` - ACI 19.2.2.1, 22.2.2.4.3, 19.2.3.1
- [X] `thickness-calc`: `min_thickness_flat_plate()` - ACI 8.3.1.1 (h = ln/33 or ln/30)
- [X] `clear-span`: `clear_span()` - ln = l - c
- [X] `static-moment`: `total_static_moment()` - ACI 8.10.3.2 (M₀ = qu×l₂×ln²/8)
- [X] `mddm-coefficients`: `MDDM_COEFFICIENTS` - Supplementary Doc Table S-1
- [X] `aci-ddm-coefficients`: `ACI_DDM_LONGITUDINAL` - ACI Tables 8.10.4.2, 8.10.5
- [X] `mddm-dist`: `distribute_moments_mddm()` - Simplified M-DDM distribution
- [X] `aci-dist`: `distribute_moments_aci()` - Full ACI DDM with l₂/l₁ ratio
- [X] `reinforcement`: `required_reinforcement()` - Supplementary Doc Eq. 1.7
- [X] `min-reinforcement`: `minimum_reinforcement()` - ACI 8.6.1.1 (0.0018×b×h)
- [X] `effective-depth`: `effective_depth()` - d = h - cover - db/2
- [X] `max-spacing`: `max_bar_spacing()` - ACI 8.7.2.2 (min(2h, 18"))
- [X] `punching-perimeter`: `punching_perimeter()` - ACI 22.6.4
- [X] `punching-capacity`: `punching_capacity_interior()` - ACI 22.6.5.2 (a,b,c criteria)
- [X] `punching-demand`: `punching_demand()` - Vu from tributary
- [X] `punching-check`: `check_punching_shear()` - φVc vs Vu
- [X] `cracked-inertia`: `cracked_moment_of_inertia()` - Transformed section Icr
- [X] `effective-inertia`: `effective_moment_of_inertia()` - ACI 24.2.3.5 (Ie)
- [X] `cracking-moment`: `cracking_moment()` - Mcr = fr×Ig/yt
- [X] `deflection-limits`: `deflection_limit()` - ACI Table 24.2.2
- [X] `long-term-factor`: `long_term_deflection_factor()` - ACI 24.2.4.1 (λΔ)

---

### Phase 2: Initial Column Estimate 🔲 NEXT

**Purpose**: Estimate column size before full design (needed for clear span ln)

**The Problem**: Slab design needs column width for clear span, but we haven't sized columns yet.

**Solution**: Estimate from tributary area and number of stories.

- [ ] `estimate-column-from-tributary`: Rule of thumb: c ≈ √(At × qu × n_stories / (0.4 × f'c))
  - Uses Voronoi tributary area (already computed)
  - Conservative estimate (tends to undersize → safe for slab clear span)
- [ ] `span-table-lookup`: Alternative: lookup from span tables (ACI-endorsed approach)
- [ ] `initial-column-storage`: Store c_initial on Column.c1, Column.c2
- [ ] `test-initial-estimate`: Verify estimates against typical values

---

### Phase 3: Concrete Column Sizing (ACI 318-19) ✅ COMPLETE

**Purpose**: Size RC columns for Pu, Mu using P-M interaction diagrams with slenderness and biaxial effects.

**Implementation Files**:
- `StructuralSizer/src/members/sections/concrete/rc_column_section.jl` - Rectangular sections
- `StructuralSizer/src/members/sections/concrete/rc_circular_section.jl` - Circular sections
- `StructuralSizer/src/members/codes/aci/pm_interaction.jl` - P-M diagram generation
- `StructuralSizer/src/members/codes/aci/phi_factors.jl` - Strength reduction factors
- `StructuralSizer/src/members/codes/aci/slenderness.jl` - Moment magnification
- `StructuralSizer/src/members/codes/aci/biaxial.jl` - Biaxial bending methods
- `StructuralSizer/src/members/codes/aci/checker.jl` - ACIColumnChecker for MIP
- `StructuralSizer/src/members/sections/concrete/catalogs/rc_columns.jl` - Section catalogs

**Validated Against**: StructurePoint spColumn examples (tied 18×18, spiral 20" circular)

- [X] `rc-column-section`: `RCColumnSection` with full rebar layout (`RebarLocation` array)
  - b, h dimensions with Unitful support
  - Perimeter and two-layer bar arrangements
  - Cover, tie_type (:tied/:spiral)
- [X] `rc-circular-section`: `RCCircularSection` for circular columns
  - D diameter, perimeter bar layout
  - Spiral confinement support
- [X] `pm-interaction-diagram`: Whitney stress block P-M analysis (ACI 22.2)
  - Strain compatibility at multiple neutral axis depths
  - Concrete displaced by steel accounted for
  - φPn vs φMn envelope generation
  - `PMInteractionDiagram` and `PMInteractionDiagramCircular` types
- [X] `phi-factors`: Strain-based φ calculation (ACI 21.2)
  - εt-based transition (0.002 to 0.005)
  - Tied: 0.65 → 0.90, Spiral: 0.75 → 0.90
- [X] `slenderness-check`: kLu/r and moment magnification (ACI 6.2.5, 6.6)
  - `slenderness_ratio()`, `should_consider_slenderness()`
  - `effective_stiffness()` - accurate (0.2EcIg + EsIse) and approximate (0.4EcIg)
  - `critical_buckling_load()` - Euler Pc
  - `magnify_moment_nonsway()` - δns with Cm factor
  - Minimum moment M_min = Pu(0.6 + 0.03h)
- [X] `biaxial-bending`: Three ACI-approved methods (ACI R6.2.6)
  - Bresler Reciprocal Load method
  - Bresler Load Contour method (β = 0.65)
  - PCA Load Contour method
- [X] `column-catalogs`: Pre-defined section libraries
  - `standard_rc_rect_columns()` - sizes 12" to 36", various ρ
  - `standard_rc_circular_columns()` - diameters 12" to 30"
  - `common_rc_rect_columns()`, `all_rc_rect_columns()`
  - `common_rc_circular_columns()`, `all_rc_circular_columns()`
- [X] `aci-column-checker`: MIP optimization interface
  - `ACIColumnChecker <: AbstractCapacityChecker`
  - `precompute_capacities!()` generates P-M diagrams
  - `is_feasible()` checks demand against diagram
  - Integrates with `size_columns()` API
- [X] `sizing-options`: `ConcreteColumnOptions` struct
  - grade, section_shape (:rect/:circular), rebar_fy
  - catalog selection, max_depth constraint
  - include_slenderness, include_biaxial flags
  - βdns for sustained load ratio
- [X] `test-column-sizing`: Comprehensive test suite
  - `test/codes/aci/test_aci_pm_interaction.jl` - P-M diagram accuracy
  - `test/codes/aci/test_aci_slenderness.jl` - Moment magnification
  - `test/codes/aci/test_aci_biaxial.jl` - Biaxial methods
  - `test/optimize/test_column_full.jl` - Full MIP integration

---

### Phase 4: EFM Analysis in ASAP 🔲

**Purpose**: Refine slab design with actual frame analysis (more accurate than DDM)

**New Function**: `to_asap_efm!(struc)` in `StructuralSynthesizer/src/analyze/asap/`

**The EFM Model**:
```
      Column Lines (N-S)
           │   │   │
    ───────●───●───●───────  ← Slab-beam elements (I_slab = l₂h³/12)
           │   │   │
    ───────●───●───●───────
           │   │   │
           ▼   ▼   ▼
        Column elements (reduced stiffness K_ec)
```

- [ ] `efm-nodes`: Create nodes at column intersections (from Column positions)
- [ ] `slab-beam-section`: Slab-beam section with I_slab = l₂ × h³/12
  - Width = transverse span l₂
  - Use h from Phase 1 DDM sizing
- [ ] `torsional-stiffness`: Kt per ACI 8.11.5.2(b)
  - C = (1 - 0.63x/y) × x³y/3
  - Kt = 9EcsC / (l₂(1 - c₂/l₂)³)
- [ ] `equivalent-column`: Kec per ACI 8.11.5
  - 1/Kec = 1/ΣKc + 1/Kt
  - Accounts for torsional flexibility of slab-column connection
- [ ] `efm-elements`: Create slab-beam and column elements in ASAP
- [ ] `efm-loads`: Apply uniform qu to slab-beams
- [ ] `solve-efm`: Solve frame in ASAP
- [ ] `extract-moments`: Get moments at face of support (not centerline)
  - M_face = M_centerline - V × c/2
- [ ] `extract-reactions`: Get column reactions (Pu, Mu) for column verification
- [ ] `compare-ddm-efm`: Check if M_efm > M_ddm (may need to increase rebar)
- [ ] `test-efm`: Validate against StructurePoint EFM example

---

### Phase 5: Final Checks & Iteration 🔲

**Purpose**: Verify design and handle cases requiring re-iteration

- [ ] `punching-with-efm-vu`: Re-check punching with actual Vu from EFM reactions
  - May differ from tributary-based estimate
- [ ] `deflection-with-efm`: Extract deflections from EFM analysis
  - Compare to limits (L/240, L/360)
- [ ] `column-verification`: Re-check columns with EFM moments
  - If M_efm > M_estimated, verify column still adequate
- [ ] `iteration-trigger`: Detect when re-iteration is needed
  - c_designed << c_initial (rare but possible)
  - M_efm >> M_ddm (irregular layouts)
  - Punching fails with actual Vu
- [ ] `reanalysis-warning`: Emit warning/error if re-iteration required
- [ ] `convergence-check`: Optional full iteration loop

---

### Phase 6: Integration & Workflow 🔲

**Purpose**: Wire everything into `size_floor(::FlatPlate, ...)` and building workflow

- [ ] `size-floor-flatplate`: `size_floor(::FlatPlate, span, sdl, live; ...)`
  - Orchestrate Phases 1-5
  - Return `FlatPlatePanelResult`
- [ ] `result-types`: `FlatPlatePanelResult`, `StripReinforcementDesign`
  - Already partially defined in `slabs/types.jl`
- [ ] `thickness-optimization`: Binary search for optimal h
  - Start at h_min, increase until all checks pass
  - Precision parameter (default 0.5")
- [ ] `story-unification`: Option to use max(h) across story
- [ ] `grouped-computation`: Leverage SlabGroup for efficiency
- [ ] `test-full-workflow`: End-to-end test with StructurePoint example
- [ ] `test-irregular-layout`: Test non-rectangular building

---

### Phase 7: Two-Stage Shell Analysis (Slabs with Beams) 🔲

**Purpose**: Alternative analysis for slabs supported on beams (not flat plates) using shell FEM for slab moments and tributary for beam forces.

**Location**: `external/Asap/src/Loads/shell_loads.jl`, `external/Asap/src/Analysis/slab_analysis.jl`

**Key Challenges Identified:**

1. **Edge Matching**: Match shell polygon edges to beam elements
2. **Interior Beams**: Accumulate loads from multiple adjacent panels
3. **Triangulation**: Group ShellTri3 elements by panel for tributary computation
4. **One-Way Control**: Coordinate orthotropic shell properties with tributary axis
5. **Boundary Conditions**: Support shell edges without over-constraining
6. **Deflection Consistency**: Shell vs beam deflections serve different design checks

**Implementation Tasks:**

- [ ] `edge-matching`: `match_beam_to_polygon_edge()` - match polygon edge to beam
  - Handle both beam orientations (start↔end swap)
  - Configurable floating-point tolerance
  - Test with offset/eccentric beams
- [ ] `shell-to-tributary`: `shell_to_tributary_loads()` - core helper function
  - Extract boundary polygon from shell nodes
  - Call `get_tributary_polygons()` for load distribution
  - Match edges to beams, create TributaryLoad for each
  - Handle case where no beam matches an edge (free edge)
- [ ] `multi-panel-accumulation`: Accumulate loads on interior beams
  - Dictionary mapping beam → list of TributaryLoads
  - Sum tributary depths from adjacent panels
  - Preserve load direction consistency
- [ ] `panel-grouping`: Group ShellTri3 elements by panel ID
  - Store panel ID on shell element (`:id` field)
  - `get_panel_boundary()` extracts outer boundary from grouped triangles
  - Handle arbitrary triangulation (2, 4, or more triangles per panel)
- [ ] `shell-model-builder`: `create_shell_model()` for Stage 1
  - Collect unique nodes from shells
  - Identify edge vs interior nodes
  - Apply "soft" simple support (w=0 only) on edge nodes
  - Create SurfaceLoad for each shell
- [ ] `two-stage-orchestrator`: `analyze_slab_system()` - main workflow
  - Stage 1: Build/solve ShellModel, extract moments/deflections
  - Stage 2: Generate TributaryLoads, build/solve FrameModel
  - Return `SlabSystemResult` with both sets of results
- [ ] `result-struct`: `SlabSystemResult` with shell moments, beam forces, both models
- [ ] `orthotropic-shell`: Support one-way slabs via orthotropic shell properties
  - `E_span >> E_perp` for one-way behavior
  - Coordinate with `axis` parameter in tributary
- [ ] `test-edge-matching`: Test beam-to-edge matching with various orientations
- [ ] `test-shell-to-tributary`: Test conversion on simple rectangular panel
- [ ] `test-interior-beam`: Test load accumulation from 2 adjacent panels
- [ ] `test-two-stage-workflow`: Full workflow test with analytical validation
- [ ] `test-one-way-vs-two-way`: Compare results with different axis settings

---

### Testing Summary

| Phase | Test File | Status |
|-------|-----------|--------|
| 1. DDM Calcs | `test_flat_plate.jl` | ✅ Complete |
| 2. Initial Column | `test_initial_column_estimate.jl` | 🔲 TODO |
| 3. Column Sizing | `test_aci_*.jl`, `test_column_full.jl` | ✅ Complete |
| 4. EFM Analysis | `test_efm_analysis.jl` | 🔲 TODO |
| 5. Final Checks | `test_design_iteration.jl` | 🔲 TODO |
| 6. Full Workflow | `test_structurepoint_full.jl` | 🔲 TODO |
| 7. Two-Stage Shell | `test_two_stage_slab.jl` | 🔲 TODO |

---

### Bonus: Column Parametric Study ✅ COMPLETE

**Location**: `StructuralStudies/src/column_properties/`

A comprehensive parametric study was conducted exploring RC column design trade-offs:

- **26,000+ configurations** swept across: shape, size, aspect ratio, f'c, fy, ρ, cover, tie type
- **Key findings**:
  - Carbon efficiency peaks at ρ ≈ 2-3%
  - Diminishing returns above f'c = 5 ksi
  - Slenderness penalty significant beyond kLu/r = 50
  - Circular spirals slightly more efficient for biaxial loading
- **Visualizations**: 18 plots in `StructuralStudies/src/column_properties/figs/`

---

## Future Enhancements 🔲

### Load Combinations

**Priority**: High - Required for production design workflows

Currently, self-weight and other loads are applied separately without formal combination support. Need to implement:

- [ ] `load-combination-types`: Define standard combinations (LRFD, ASD)
  - 1.2D + 1.6L (LRFD gravity)
  - 1.2D + 1.0L + 1.0E (seismic)
  - 0.9D + 1.0E (overturning check - dead load helps resist)
  - D + L (ASD)
- [ ] `load-case-management`: Track loads by type (D, L, Lr, S, W, E)
  - `SelfWeight` → Dead (D)
  - `AreaLoad` → depends on use (LL, SDL, etc.)
  - Tag loads with case type at creation
- [ ] `factored-load-api`: Scale and combine load cases
  - `scale(load, factor)` → factored load
  - `combine(load_cases, factors)` → combined load set
- [ ] `envelope-results`: Envelope analysis across combinations
  - Max/min moments, shears, deflections
  - Critical combination identification
- [ ] `solve-combinations`: Efficient multi-case solving
  - `solve!(model, combinations)` → results per combination
  - Reuse stiffness matrix, only re-solve load vectors

**Design Considerations**:
- Self-weight is factored differently than live load
- Some combinations have dead load helping (0.9D for overturning)
- Pattern loading for high L/D ratios (see memory: pattern loading deferred for L/D < 0.75)

**Potential API**:
```julia
# Define load cases
DL = SelfWeight(model)
SDL = AreaLoad(shells, 1.0u"kPa"; case=:dead)
LL = AreaLoad(shells, 2.5u"kPa"; case=:live)

# Define combinations
combos = [
    LoadCombination(:LRFD_gravity, [1.2, 1.2, 1.6], [DL, SDL, LL]),
    LoadCombination(:LRFD_seismic, [0.9, 0.9, 0.0], [DL, SDL, LL]),
]

# Solve all combinations
results = solve!(model, combos)

# Envelope
M_max, M_min, governing_combo = envelope(results, :moment)
```

---

### Sway Frame Moment Amplification (P-Δ Effects)

**Priority**: Medium - Required for unbraced frames with lateral loads

Both **RC columns** (ACI 318-19 §6.6) and **steel columns** (AISC 360-16 Appendix 8) require moment amplification for P-Δ effects when the frame is unbraced (sway frame). Currently the implementation assumes braced frames (`braced=true`).

#### What's Implemented

| Material | Non-sway (P-δ) | Sway (P-Δ) | Status |
|----------|----------------|------------|--------|
| **Steel** | B1 factor implemented | B2 factor implemented | ⚠️ Not integrated into `AISCChecker` |
| **RC** | `magnify_moment_nonsway()` | `magnify_moment_sway_complete()` | ⚠️ Not integrated into column sizing |

#### Required for Full Implementation

**1. Story-Level Data Collection** (needed for both materials):
- `ΣPu`: Total factored vertical load in story
- `ΣPc` (RC) or `Pe_story` (steel): Elastic critical buckling strength for story
- `Vus`: Total lateral shear in story
- `Δo`: First-order interstory drift
- `lc`: Story height

**2. RC Columns** (ACI 6.6.4.6):
- [ ] `story-properties-extraction`: Extract story data from ASAP model after analysis
- [ ] `sway-magnification-integration`: Call `magnify_moment_sway_complete()` in `ACIColumnChecker`
- [ ] `braced-flag-rc-column`: Add `braced::Bool` field to RC column demand/geometry

**3. Steel Columns** (AISC Appendix 8):
- [ ] `b1-integration`: Amplify `Mnt` by B1 in `AISCChecker.is_feasible()` before interaction check
- [ ] `b2-integration`: When `braced=false`, compute B2 and amplify `Mlt`, `Plt`
- [ ] `story-properties-steel`: Same story data needed as for RC

**4. API Considerations**:
```julia
# Current: braced=true by default
geom = SteelMemberGeometry(L; Lb=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)

# For sway frames, user provides story properties:
story = StoryProperties(ΣPu=1500kip, H=20kip, L=12ft, ΔH=0.5inch, Pmf=500kip)
geom_sway = SteelMemberGeometry(L; braced=false, story_properties=story)

# Checker then computes B2 internally and amplifies moments
```

**5. Testing**:
- [ ] Validate against AISC Design Examples for moment frames
- [ ] Validate against StructurePoint for RC sway frames
- [ ] Add integration tests for story property extraction from ASAP