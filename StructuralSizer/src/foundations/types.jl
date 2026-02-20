# Foundation type hierarchy and result types

# =============================================================================
# Abstract Hierarchy
# =============================================================================

abstract type AbstractFoundation end

# --- Shallow Foundations ---
abstract type AbstractShallowFoundation <: AbstractFoundation end

struct SpreadFooting <: AbstractShallowFoundation end
struct CombinedFooting <: AbstractShallowFoundation end
struct StripFooting <: AbstractShallowFoundation end
struct MatFoundation <: AbstractShallowFoundation end

# --- Deep Foundations ---
abstract type AbstractDeepFoundation <: AbstractFoundation end

struct DrivenPile <: AbstractDeepFoundation end
struct DrilledShaft <: AbstractDeepFoundation end
struct Micropile <: AbstractDeepFoundation end

# =============================================================================
# Soil Properties
# =============================================================================

"""
    Soil{T_P, T_D}

Geotechnical soil parameters for foundation design.

# Fields
- `qa`: Allowable bearing capacity (pressure)
- `γ`: Unit weight (force/volume)
- `ϕ`: Internal friction angle (degrees)
- `c`: Cohesion (pressure)
- `Es`: Soil elastic modulus (pressure) for settlement
- `qs`: Unit skin friction for piles (pressure), optional
- `qp`: Unit end bearing for piles (pressure), optional
- `ks`: Modulus of subgrade reaction (force/length³), optional — for Winkler analysis
"""
struct Soil{T_P, T_D}
    qa::T_P         # Allowable bearing capacity
    γ::T_D          # Unit weight (force/volume, e.g. kN/m³)
    ϕ::Float64      # Friction angle (degrees)
    c::T_P          # Cohesion
    Es::T_P         # Soil modulus
    qs::Union{T_P, Nothing}  # Skin friction (piles)
    qp::Union{T_P, Nothing}  # End bearing (piles)
    ks::Union{T_D, Nothing}  # Modulus of subgrade reaction (force/length³, same dim as γ)
end

function Soil(qa, γ, ϕ, c, Es; qs=nothing, qp=nothing, ks=nothing)
    Soil{typeof(qa), typeof(γ)}(qa, γ, Float64(ϕ), c, Es, qs, qp, ks)
end

# Common soil presets
# ks values from Bowles (1996) Table 9-1 and ACI 336.2R
# Note: ks (modulus of subgrade reaction) has dimension force/length³ = same as γ.
#       Express in kN/m³ to match γ's Unitful type (T_D).
const loose_sand = Soil(
    75.0u"kPa",         # qa
    16.0u"kN/m^3",      # γ
    28.0,               # ϕ
    0.0u"kPa",          # c
    10.0u"MPa";         # Es
    ks = 5000.0u"kN/m^3"  # Bowles Table 9-1: loose sand
)

const medium_sand = Soil(
    150.0u"kPa",        # qa
    18.0u"kN/m^3",      # γ
    32.0,               # ϕ
    0.0u"kPa",          # c
    25.0u"MPa";         # Es
    ks = 25000.0u"kN/m^3"  # Bowles Table 9-1: medium sand
)

const dense_sand = Soil(
    300.0u"kPa",        # qa
    20.0u"kN/m^3",      # γ
    38.0,               # ϕ
    0.0u"kPa",          # c
    50.0u"MPa";         # Es
    ks = 100000.0u"kN/m^3"  # Bowles Table 9-1: dense sand
)

const soft_clay = Soil(
    50.0u"kPa",         # qa
    16.0u"kN/m^3",      # γ
    0.0,                # ϕ
    25.0u"kPa",         # c (undrained shear strength)
    5.0u"MPa";          # Es
    ks = 12000.0u"kN/m^3"  # Bowles Table 9-1: soft clay
)

const stiff_clay = Soil(
    150.0u"kPa",        # qa
    19.0u"kN/m^3",      # γ
    0.0,                # ϕ
    75.0u"kPa",         # c
    20.0u"MPa";         # Es
    ks = 50000.0u"kN/m^3"  # Bowles Table 9-1: stiff clay
)

const hard_clay = Soil(
    300.0u"kPa",        # qa
    21.0u"kN/m^3",      # γ
    0.0,                # ϕ
    150.0u"kPa",        # c
    50.0u"MPa";         # Es
    ks = 150000.0u"kN/m^3"  # Bowles Table 9-1: hard clay
)

# =============================================================================
# Result Types
# =============================================================================

abstract type AbstractFoundationResult end

"""
    SpreadFootingResult{L, V, F}

Design result for a spread (isolated) footing.

# Fields
- `B`: Footing width (square) or length
- `L`: Footing length (for rectangular; equals B for square)
- `D`: Footing depth/thickness
- `d`: Effective depth (to centroid of rebar)
- `As`: Rebar area per unit width
- `rebar_count`: Number of bars each way
- `rebar_dia`: Rebar diameter
- `concrete_volume`: Total concrete volume
- `steel_volume`: Total rebar volume
- `utilization`: Bearing pressure ratio (demand/capacity)
"""
struct SpreadFootingResult{L, V, F} <: AbstractFoundationResult
    B::L                # Width (m)
    L_ftg::L            # Length (m; L_ftg to avoid conflict with L type param)
    D::L                # Depth/thickness (m)
    d::L                # Effective depth (m)
    As::L               # Rebar area per unit width (m²/m = m)
    rebar_count::Int    # Number of bars each direction
    rebar_dia::L        # Rebar diameter (m)
    concrete_volume::V  # Total concrete (m³)
    steel_volume::V     # Total rebar (m³)
    utilization::Float64
end

"""
    CombinedFootingResult{L, V, F}

Design result for a combined footing supporting multiple columns.
"""
struct CombinedFootingResult{L, V, F} <: AbstractFoundationResult
    B::L                # Width (m)
    L_ftg::L            # Length (m)
    D::L                # Depth (m)
    d::L                # Effective depth (m)
    As_bot::L           # Bottom rebar area per width (m²/m = m)
    As_top::L           # Top rebar area per width (m²/m = m)
    concrete_volume::V  # (m³)
    steel_volume::V     # (m³)
    utilization::Float64
end

"""
    StripFootingResult{L, V, F}

Design result for a strip (combined) footing supporting N ≥ 2 columns.

# Fields
- `B`: Footing width
- `L_ftg`: Total length
- `D`: Footing depth/thickness
- `d`: Effective depth
- `As_long_bot`: Bottom longitudinal steel area
- `As_long_top`: Top longitudinal steel area (negative moment)
- `As_trans`: Transverse steel area per unit length under column bands
- `n_columns`: Number of columns supported
- `concrete_volume`: Total concrete volume
- `steel_volume`: Total rebar volume
- `utilization`: Governing utilization ratio
"""
struct StripFootingResult{L, A, V, F} <: AbstractFoundationResult
    B::L
    L_ftg::L
    D::L
    d::L
    As_long_bot::A   # Area (in² or m²)
    As_long_top::A   # Area (in² or m²)
    As_trans::A       # Area (in² or m²)
    n_columns::Int
    concrete_volume::V
    steel_volume::V
    utilization::Float64
end

"""
    MatFootingResult{L, V, F}

Design result for a mat foundation.

# Fields
- `B`: Mat width
- `L_ftg`: Mat length
- `D`: Mat thickness
- `d`: Effective depth
- `As_x_bot`, `As_x_top`: X-direction reinforcement (bottom/top)
- `As_y_bot`, `As_y_top`: Y-direction reinforcement (bottom/top)
- `n_columns`: Number of columns supported
- `concrete_volume`: Total concrete volume
- `steel_volume`: Total rebar volume
- `utilization`: Governing utilization ratio
"""
struct MatFootingResult{L, A, V, F} <: AbstractFoundationResult
    B::L
    L_ftg::L
    D::L
    d::L
    As_x_bot::A
    As_x_top::A
    As_y_bot::A
    As_y_top::A
    n_columns::Int
    concrete_volume::V
    steel_volume::V
    utilization::Float64
end

"""
    PileCapResult{L, V}

Design result for a pile group with cap.
"""
struct PileCapResult{L, V} <: AbstractFoundationResult
    n_piles::Int        # Number of piles
    pile_dia::L         # Pile diameter
    pile_length::L      # Pile embedment length
    pile_spacing::L     # Center-to-center spacing
    cap_B::L            # Pile cap width
    cap_L::L            # Pile cap length  
    cap_D::L            # Pile cap depth
    concrete_volume::V  # Cap + piles (if cast-in-place)
    steel_volume::V     # Reinforcement volume
    utilization::Float64
end

# =============================================================================
# Common Interface
# =============================================================================

"""Concrete volume of foundation."""
concrete_volume(r::AbstractFoundationResult) = r.concrete_volume

"""Steel/rebar volume of foundation."""
steel_volume(r::AbstractFoundationResult) = r.steel_volume

"""Overall footprint area."""
footprint_area(r::SpreadFootingResult) = r.B * r.L_ftg
footprint_area(r::CombinedFootingResult) = r.B * r.L_ftg
footprint_area(r::StripFootingResult) = r.B * r.L_ftg
footprint_area(r::MatFootingResult) = r.B * r.L_ftg
footprint_area(r::PileCapResult) = r.cap_B * r.cap_L

"""Footing length (plan dimension)."""
footing_length(r::AbstractFoundationResult) = r.L_ftg
footing_length(r::PileCapResult) = r.cap_L

"""Footing width (plan dimension)."""
footing_width(r::AbstractFoundationResult) = r.B
footing_width(r::PileCapResult) = r.cap_B

"""Utilization ratio (demand/capacity)."""
utilization(r::AbstractFoundationResult) = r.utilization

# =============================================================================
# Foundation Demand
# =============================================================================

"""
    FoundationDemand{F, M, L}

Reaction forces from structural analysis at a support node, with per-column
dimensions for punching shear, bearing, and development checks.

# Fields
- `Pu`: Factored axial load (compression positive)
- `Mux`: Factored moment about x-axis
- `Muy`: Factored moment about y-axis
- `Vux`: Factored shear in x
- `Vuy`: Factored shear in y
- `Ps`: Service axial load (for settlement)
- `c1`: Column dimension parallel to footing length (or diameter for circular)
- `c2`: Column dimension perpendicular (= c1 for square/circular)
- `shape`: `:rectangular` or `:circular`
"""
struct FoundationDemand{F, M, L}
    group_idx::Int
    Pu::F       # Factored axial (compression +)
    Mux::M      # Moment about x
    Muy::M      # Moment about y
    Vux::F      # Shear x
    Vuy::F      # Shear y
    Ps::F       # Service axial (for settlement)
    c1::L       # Column dim 1 (or diameter)
    c2::L       # Column dim 2 (= c1 for circular)
    shape::Symbol   # :rectangular or :circular
end

function FoundationDemand(idx::Int;
                          Pu=0.0u"kN", Mux=0.0u"kN*m", Muy=0.0u"kN*m",
                          Vux=0.0u"kN", Vuy=0.0u"kN", Ps=0.0u"kN",
                          c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
    FoundationDemand{typeof(Pu), typeof(Mux), typeof(c1)}(
        idx, Pu, Mux, Muy, Vux, Vuy, Ps, c1, c2, shape)
end

# =============================================================================
# Symbol ↔ Type Mapping
# =============================================================================

const foundation_type_map = Dict{Symbol, AbstractFoundation}(
    :spread => SpreadFooting(),
    :combined => CombinedFooting(),
    :strip => StripFooting(),
    :mat => MatFoundation(),
    :driven_pile => DrivenPile(),
    :drilled_shaft => DrilledShaft(),
    :micropile => Micropile(),
)

const foundation_symbol_map = Dict{Type, Symbol}(
    typeof(v) => k for (k, v) in pairs(foundation_type_map)
)

"""Convert symbol to foundation type for dispatch."""
function foundation_type(s::Symbol)
    haskey(foundation_type_map, s) || throw(KeyError("Unknown foundation type: $s"))
    return foundation_type_map[s]
end

"""Convert foundation type to symbol for storage."""
function foundation_symbol(t::AbstractFoundation)
    T = typeof(t)
    haskey(foundation_symbol_map, T) || throw(KeyError("Unknown foundation type: $T"))
    return foundation_symbol_map[T]
end
