# =============================================================================
# Design Result Types
# =============================================================================
#
# Separates building geometry/loads (BuildingStructure) from design results
# (BuildingDesign). This enables:
#   - Multiple designs for the same building (different materials)
#   - Parametric studies (sweep f'c, thickness, etc.)
#   - Design comparison and optimization
#
# Architecture:
#   BuildingStructure          → geometry, loads, tributaries (see building_types.jl)
#   BuildingDesign             → design results for a specific parameter set
#   DesignParameters           → material choices, optimization targets
# =============================================================================

using Dates
using Unitful

# =============================================================================
# Foundation Parameters
# =============================================================================

"""
Foundation sizing parameters.

# Fields
- `soil`: Soil profile (bearing capacity, settlement params)
- `concrete`: Concrete grade for footings
- `rebar`: Rebar grade for footings
- `pier_width`: Column/pier width for sizing
- `min_depth`: Minimum footing depth (frost line, etc.)
- `group_tolerance`: Tolerance for grouping similar foundations (default 0.15 = 15%)

# Example
```julia
fp = FoundationParameters(
    soil = MEDIUM_SAND,
    concrete = NWC_4000,
    min_depth = 0.5u"m",
)
```
"""
Base.@kwdef struct FoundationParameters
    soil::StructuralSizer.Soil = StructuralSizer.MEDIUM_SAND
    concrete::StructuralSizer.Concrete = StructuralSizer.NWC_4000
    rebar::StructuralSizer.RebarSteel = StructuralSizer.Rebar_60
    pier_width::typeof(1.0u"m") = 0.35u"m"
    min_depth::typeof(1.0u"m") = 0.4u"m"
    group_tolerance::Float64 = 0.15
end

# =============================================================================
# Design Parameters
# =============================================================================

"""
Parameters that define a design configuration.

Different `DesignParameters` on the same `BuildingStructure` produce
different `BuildingDesign` results, enabling parametric studies.

# Materials
Use existing types from StructuralSizer:
- `concrete::Concrete` - with fc′, E, ρ, etc.
- `steel::StructuralSteel` - with Fy, Fu, E, etc.
- `rebar::RebarSteel` - for reinforcement

# Member Sizing Options
Optional overrides for column/beam sizing:
- `columns`: `SteelColumnOptions` or `ConcreteColumnOptions`
- `beams`: `SteelBeamOptions`

# Analysis Settings
- `load_combination::LoadCombination` - Load factors (default: STRENGTH_1_2D_1_6L)
- `diaphragm_mode::Symbol` - `:none`, `:rigid`, or `:shell`
- `default_frame_E/G/ρ` - Placeholder frame properties before sizing
- `column_I_factor` / `beam_I_factor` - ACI cracking factors for effective stiffness

# Example
```julia
# Simple: just set materials
params = DesignParameters(
    steel = A992_Steel,
    concrete = NWC_5000,
)

# Full control: materials, sizing, and analysis
params = DesignParameters(
    name = "High-Rise Office",
    
    # Materials
    steel = A992_Steel,
    concrete = NWC_5000,
    
    # Concrete columns with specific settings
    columns = ConcreteColumnOptions(
        grade = NWC_5000,
        max_depth = 0.6,
    ),
    
    # Steel beams with strict deflection
    beams = SteelBeamOptions(
        deflection_limit = 1/480,
    ),
    
    # Analysis settings
    load_combination = STRENGTH_1_2D_1_6L,
    diaphragm_mode = :rigid,
    
    optimize_for = :carbon,
)

# Use serviceability combination for deflection checks
service_params = DesignParameters(
    load_combination = SERVICE,  # 1.0D + 1.0L
)

# Then sizing auto-uses these:
size_columns!(struc)  # uses params.columns
size_beams!(struc)    # uses params.beams
```
"""
Base.@kwdef mutable struct DesignParameters
    # Identifiers
    name::String = "default"
    description::String = ""
    
    # ─── Materials ───
    # Defaults for the building (used when section-specific material not provided)
    concrete::Union{StructuralSizer.Concrete, Nothing} = nothing
    steel::Union{StructuralSizer.StructuralSteel, Nothing} = nothing
    rebar::Union{StructuralSizer.RebarSteel, Nothing} = nothing
    timber::Union{StructuralSizer.Timber, Nothing} = nothing
    
    # ─── Member Sizing Options ───
    # Override material defaults for specific member types
    columns::Union{StructuralSizer.SteelColumnOptions, StructuralSizer.ConcreteColumnOptions, Nothing} = nothing
    beams::Union{StructuralSizer.SteelBeamOptions, Nothing} = nothing
    
    # ─── Floor Options ───
    floor_options::Union{StructuralSizer.FloorOptions, Nothing} = nothing
    
    # ─── Foundation Options ───
    foundation_options::Union{FoundationParameters, Nothing} = nothing
    
    # ─── Design Targets ───
    deflection_limit::Symbol = :L_360        # :L_240, :L_360, :L_480
    optimize_for::Symbol = :weight           # :weight, :carbon, :cost
    
    # ─── Analysis Settings ───
    # Load combination (replaces hardcoded DL/LL factors)
    load_combination::LoadCombination = DEFAULT_STRENGTH
    
    # Diaphragm modeling for lateral analysis
    diaphragm_mode::Symbol = :none           # :none, :rigid, :shell
    diaphragm_E::Union{typeof(1.0u"Pa"), Nothing} = nothing  # override E (default: 1e15 Pa for rigid, 30 GPa for shell)
    diaphragm_ν::Float64 = 0.2
    
    # Default frame element properties (before member sizing)
    # Used as placeholder section in to_asap! before actual sizing
    default_frame_E::typeof(1.0u"Pa") = 200e9u"Pa"      # Steel default
    default_frame_G::typeof(1.0u"Pa") = 77e9u"Pa"       # Steel default
    default_frame_ρ::typeof(1.0u"kg/m^3") = 7850.0u"kg/m^3"
    
    # ─── ACI Cracking Factors ───
    # For converting RC sections to Asap.Section (effective stiffness)
    column_I_factor::Float64 = 0.70    # ACI 318-14 §6.6.3.1.1 for columns
    beam_I_factor::Float64 = 0.35      # ACI 318-14 §6.6.3.1.1 for beams
end

# =============================================================================
# Design Results
# =============================================================================

"""
Strip reinforcement design at a moment location.
"""
struct StripReinforcementDesign
    Mu::typeof(1.0u"kN*m")           # Factored moment
    As_required::typeof(1.0u"mm^2")  # Required steel area
    As_minimum::typeof(1.0u"mm^2")   # Minimum steel area
    As_provided::typeof(1.0u"mm^2")  # Provided steel area
    bar_size::String                  # e.g., "#5", "16M"
    spacing::typeof(1.0u"mm")         # Bar spacing
    n_bars::Int                       # Number of bars
end

"""
Design result for a slab panel.
"""
Base.@kwdef mutable struct SlabDesignResult
    # Sizing
    thickness::typeof(1.0u"mm")
    self_weight::typeof(1.0u"kN/m^2")
    
    # Analysis
    M0::Union{typeof(1.0u"kN*m"), Nothing} = nothing  # Total static moment
    
    # Reinforcement (by location)
    column_strip::Dict{Symbol, StripReinforcementDesign} = Dict()  # :ext_neg, :pos, :int_neg
    middle_strip::Dict{Symbol, StripReinforcementDesign} = Dict()
    
    # Checks
    deflection_ok::Bool = true
    deflection_ratio::Float64 = 0.0  # actual / limit
end

"""
Punching shear check result for a column.
"""
Base.@kwdef mutable struct PunchingCheckResult
    Vu::typeof(1.0u"kN")             # Demand
    φVc::typeof(1.0u"kN")            # Capacity (factored)
    ratio::Float64                    # Vu / φVc
    ok::Bool                          # ratio ≤ 1.0
    critical_perimeter::typeof(1.0u"mm")
    tributary_area::typeof(1.0u"m^2")
end

"""
Design result for a column.
"""
Base.@kwdef mutable struct ColumnDesignResult
    # Sizing
    section_size::String = ""         # e.g., "W14x90", "16x16"
    
    # Demands
    Pu::typeof(1.0u"kN") = 0.0u"kN"
    Mu_x::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Mu_y::typeof(1.0u"kN*m") = 0.0u"kN*m"
    
    # Capacity ratios
    axial_ratio::Float64 = 0.0
    interaction_ratio::Float64 = 0.0
    ok::Bool = true
    
    # Punching (if supporting flat slab)
    punching::Union{PunchingCheckResult, Nothing} = nothing
end

"""
Design result for a beam.
"""
Base.@kwdef mutable struct BeamDesignResult
    section_size::String = ""
    Mu::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Vu::typeof(1.0u"kN") = 0.0u"kN"
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
end

"""
Design result for a foundation.
"""
Base.@kwdef mutable struct FoundationDesignResult
    # Geometry
    length::typeof(1.0u"m") = 0.0u"m"
    width::typeof(1.0u"m") = 0.0u"m"
    depth::typeof(1.0u"m") = 0.0u"m"
    
    # Demands
    reaction::typeof(1.0u"kN") = 0.0u"kN"
    
    # Checks
    bearing_ratio::Float64 = 0.0      # actual / allowable bearing pressure
    punching_ratio::Float64 = 0.0     # punching shear check
    flexure_ratio::Float64 = 0.0      # flexure check
    ok::Bool = true
    
    # Group assignment
    group_id::Int = 0
end

"""
Design summary with aggregate metrics.
"""
Base.@kwdef mutable struct DesignSummary
    # Volumes/weights
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_weight::typeof(1.0u"kg") = 0.0u"kg"
    rebar_weight::typeof(1.0u"kg") = 0.0u"kg"
    timber_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    
    # Derived metrics
    embodied_carbon::Float64 = 0.0    # kgCO₂e
    cost_estimate::Float64 = 0.0      # $
    
    # Status
    all_checks_pass::Bool = true
    critical_element::String = ""      # Element with highest ratio
    critical_ratio::Float64 = 0.0
end

"""
A complete design solution for a BuildingStructure.

Holds a reference to the source `BuildingStructure` for geometry access,
enabling a clean API: `visualize(design)` works without passing structure separately.

Multiple BuildingDesign instances can reference the same BuildingStructure,
enabling comparison of different material choices or optimization targets.

# Example
```julia
building = BuildingStructure(skeleton)
# ... initialize cells, members ...

design1 = BuildingDesign(building, DesignParameters(
    name = "Concrete 4ksi",
    concrete = NWC_4000
))

design2 = BuildingDesign(building, DesignParameters(
    name = "Concrete 6ksi", 
    concrete = NWC_6000
))

visualize(design1)  # Self-contained: accesses geometry via design.structure
compare_designs(design1, design2)
```
"""
mutable struct BuildingDesign{T, A, P}
    # Reference to source building (pointer, not copy)
    structure::BuildingStructure{T, A, P}
    
    # Design configuration
    params::DesignParameters
    
    # Design results (keyed by member index)
    slabs::Dict{Int, SlabDesignResult}
    columns::Dict{Int, ColumnDesignResult}
    beams::Dict{Int, BeamDesignResult}
    foundations::Dict{Int, FoundationDesignResult}
    
    # Summary
    summary::DesignSummary
    
    # ─── Analysis Model ───
    # Frame+shell model for global deflection analysis (built after design)
    # Separate from struc.asap_model to preserve the design-phase frame model
    asap_model::Union{Asap.Model, Nothing}
    
    # Metadata
    created::DateTime
    compute_time_s::Float64
end

function BuildingDesign(struc::BuildingStructure{T, A, P}, params::DesignParameters=DesignParameters()) where {T, A, P}
    BuildingDesign{T, A, P}(
        struc,
        params,
        Dict{Int, SlabDesignResult}(),
        Dict{Int, ColumnDesignResult}(),
        Dict{Int, BeamDesignResult}(),
        Dict{Int, FoundationDesignResult}(),
        DesignSummary(),
        nothing,  # asap_model (built via build_analysis_model!)
        now(),
        0.0
    )
end

# =============================================================================
# BuildingDesign Accessors
# =============================================================================

"""Get the source BuildingStructure."""
structure(d::BuildingDesign) = d.structure

"""Get the source BuildingSkeleton (shorthand for d.structure.skeleton)."""
skeleton(d::BuildingDesign) = d.structure.skeleton

"""Get slab design result by index."""
slab_design(d::BuildingDesign, idx::Int) = get(d.slabs, idx, nothing)

"""Get column design result by index."""
column_design(d::BuildingDesign, idx::Int) = get(d.columns, idx, nothing)

"""Get beam design result by index."""
beam_design(d::BuildingDesign, idx::Int) = get(d.beams, idx, nothing)

"""Get foundation design result by index."""
foundation_design(d::BuildingDesign, idx::Int) = get(d.foundations, idx, nothing)

"""Check if all design checks pass."""
all_ok(d::BuildingDesign) = d.summary.all_checks_pass

"""Get the governing (critical) design ratio."""
critical_ratio(d::BuildingDesign) = d.summary.critical_ratio

"""Check if the analysis model (frame+shell) has been built."""
has_analysis_model(d::BuildingDesign) = !isnothing(d.asap_model)
