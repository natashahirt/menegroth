# Foundation type hierarchy and result types

# =============================================================================
# Abstract Hierarchy
# =============================================================================

"""Supertype for all foundation types (shallow and deep)."""
abstract type AbstractFoundation end

# --- Shallow Foundations ---

"""Supertype for shallow foundation types (spread, combined, strip, mat)."""
abstract type AbstractShallowFoundation <: AbstractFoundation end

"""Singleton type for spread (isolated) footing dispatch."""
struct SpreadFooting <: AbstractShallowFoundation end

"""Singleton type for combined footing dispatch."""
struct CombinedFooting <: AbstractShallowFoundation end

"""Singleton type for strip (continuous) footing dispatch."""
struct StripFooting <: AbstractShallowFoundation end

"""Singleton type for mat (raft) foundation dispatch."""
struct MatFoundation <: AbstractShallowFoundation end

# --- Deep Foundations ---

"""Supertype for deep foundation types (piles, shafts, micropiles)."""
abstract type AbstractDeepFoundation <: AbstractFoundation end

"""Singleton type for driven pile dispatch."""
struct DrivenPile <: AbstractDeepFoundation end

"""Singleton type for drilled shaft (caisson) dispatch."""
struct DrilledShaft <: AbstractDeepFoundation end

"""Singleton type for micropile dispatch."""
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

"""
    Soil(qa, γ, ϕ, c, Es; qs=nothing, qp=nothing, ks=nothing) → Soil

Convenience constructor that infers parametric types from `qa` (pressure)
and `γ` (force/volume). Pile-specific fields `qs`, `qp`, and Winkler
modulus `ks` are optional.
"""
function Soil(qa, γ, ϕ, c, Es; qs=nothing, qp=nothing, ks=nothing)
    Soil{typeof(qa), typeof(γ)}(qa, γ, Float64(ϕ), c, Es, qs, qp, ks)
end

"""Preset: loose sand — qa = 75 kPa, ks = 5 000 kN/m³ (Bowles 1996 Table 9-1)."""
const loose_sand = Soil(
    75.0u"kPa",         # qa
    16.0u"kN/m^3",      # γ
    28.0,               # ϕ
    0.0u"kPa",          # c
    10.0u"MPa";         # Es
    ks = 5000.0u"kN/m^3"  # Bowles Table 9-1: loose sand
)

"""Preset: medium sand — qa = 150 kPa, ks = 25 000 kN/m³ (Bowles 1996 Table 9-1)."""
const medium_sand = Soil(
    150.0u"kPa",        # qa
    18.0u"kN/m^3",      # γ
    32.0,               # ϕ
    0.0u"kPa",          # c
    25.0u"MPa";         # Es
    ks = 25000.0u"kN/m^3"  # Bowles Table 9-1: medium sand
)

"""Preset: dense sand — qa = 300 kPa, ks = 100 000 kN/m³ (Bowles 1996 Table 9-1)."""
const dense_sand = Soil(
    300.0u"kPa",        # qa
    20.0u"kN/m^3",      # γ
    38.0,               # ϕ
    0.0u"kPa",          # c
    50.0u"MPa";         # Es
    ks = 100000.0u"kN/m^3"  # Bowles Table 9-1: dense sand
)

"""Preset: soft clay — qa = 50 kPa, ks = 12 000 kN/m³ (Bowles 1996 Table 9-1)."""
const soft_clay = Soil(
    50.0u"kPa",         # qa
    16.0u"kN/m^3",      # γ
    0.0,                # ϕ
    25.0u"kPa",         # c (undrained shear strength)
    5.0u"MPa";          # Es
    ks = 12000.0u"kN/m^3"  # Bowles Table 9-1: soft clay
)

"""Preset: stiff clay — qa = 150 kPa, ks = 50 000 kN/m³ (Bowles 1996 Table 9-1)."""
const stiff_clay = Soil(
    150.0u"kPa",        # qa
    19.0u"kN/m^3",      # γ
    0.0,                # ϕ
    75.0u"kPa",         # c
    20.0u"MPa";         # Es
    ks = 50000.0u"kN/m^3"  # Bowles Table 9-1: stiff clay
)

"""Preset: hard clay — qa = 300 kPa, ks = 150 000 kN/m³ (Bowles 1996 Table 9-1)."""
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

"""Supertype for all foundation design result structs."""
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
- `utilization`: Utilization ratio reported by the design routine (for ACI spread footings this is currently the max of punching utilization and service bearing utilization)
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
- `As_tensile`: Interface tensile steel across mixed-sign column-footing
  joints (ACI 318-11 §15.8.1.2(b), corpus: aci-318-11, page 275).  Zero
  when every column is in compression.
- `Bn`: Design bearing strength φBn of the footing concrete at the
  governing (minimum-sqA) column interface (ACI 318-11 §10.14.1 /
  §15.8.1.1, corpus: aci-318-11, pages 162, 274). Zero when no
  compression column is checked.
- `sqA`: √(A2/A1) ≤ 2 used for that Bn (1 when the support is not
  wider on all sides than the loaded area).
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
    As_tensile::A    # §15.8.1.2(b) tensile interface steel
    Bn::F            # φBn_footing at governing (min sqA) column
    sqA::Float64     # √(A2/A1) ≤ 2 at that column
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

"""Overall footprint area (length²)."""
footprint_area(r::SpreadFootingResult) = r.B * r.L_ftg
"""Overall footprint area (length²)."""
footprint_area(r::CombinedFootingResult) = r.B * r.L_ftg
"""Overall footprint area (length²)."""
footprint_area(r::StripFootingResult) = r.B * r.L_ftg
"""Overall footprint area (length²)."""
footprint_area(r::MatFootingResult) = r.B * r.L_ftg
"""Overall footprint area of pile cap (length²)."""
footprint_area(r::PileCapResult) = r.cap_B * r.cap_L

"""Footing length (plan dimension)."""
footing_length(r::AbstractFoundationResult) = r.L_ftg
"""Pile cap length (plan dimension)."""
footing_length(r::PileCapResult) = r.cap_L

"""Footing width (plan dimension)."""
footing_width(r::AbstractFoundationResult) = r.B
"""Pile cap width (plan dimension)."""
footing_width(r::PileCapResult) = r.cap_B

"""Footing overall thickness (depth)."""
footing_depth(r::AbstractFoundationResult) = r.D
"""Pile cap thickness (depth)."""
footing_depth(r::PileCapResult) = r.cap_D

"""Utilization ratio (demand/capacity)."""
utilization(r::AbstractFoundationResult) = r.utilization

# =============================================================================
# Imperial length canonicalize (bearing / strip stations)
# =============================================================================

# SI m↔inch of 1 ft is 0.3048/0.0254 = 12 + ~1.78e-15, not Unitful's exact
# ×12. That ulp is conversion noise, not a construction leftover (0.01 in
# is ~1e10× larger) and not an ε-not-wider rule. Do not grid-round the
# station onto a 1e-12 leftover: `round(x/1e-12)*1e-12` sends 12+6e-13 to
# 12+1e-12 (`left` ≈ 1.00009e-12, still `left > 0`). Snap the four
# overhangs after face subtraction (`_snap_si_overhang`). Production
# leftover is inch-tagged after SI round-trip (`uconvert(inch,
# uconvert(m, 1ft))` ≈ 12 + 1.78e-15); a tag bypass lets `left > 0` open
# ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162).
const _SI_INCH_ULP = 1e-12

"""
    _canonical_inch(L) → Quantity in inches

Convert a length to inches before mixed-unit arithmetic.

Every unit, including already-tagged inch/ft: an inch-tagged SI leftover
is still 0.3048/0.0254, not ×12. Do not grid-round onto leftover (6e-13
must not become 1e-12). SI residuals are snapped on the four overhangs
after face subtraction (`_snap_si_overhang`). A true leftover (e.g.
0.01 in) is unchanged. Not a construction tolerance and not an
ε-not-wider rule (ACI 318-11 §10.14.1, corpus: aci-318-11, page 162).
"""
function _canonical_inch(L::Length)
    return ustrip(u"inch", L) * u"inch"
end

"""Same as `_canonical_inch`, then exact ÷12 to feet."""
_canonical_ft(L::Length) = uconvert(u"ft", _canonical_inch(L))

"""
    _snap_si_overhang(oh) → Length

After face subtraction, treat `|overhang| ≤ `_SI_INCH_ULP` (1e-12 in) as
zero (inclusive). Exclusive `<` leaves `col_along = (12+1e-12)inch`
wider: Unitful inflates that bound to ~1.00009e-12 in after subtract.
That residual is still SI-conversion noise — not a construction
tolerance (0.01 in leftover is ~1e10× larger) and not an ε-not-wider
rule. Used for the ACI 318-11 §10.14.1 wider-on-all-sides gate and
that face's A2 clip (corpus: aci-318-11, page 162).
"""
function _snap_si_overhang(oh::Length)
    x = ustrip(u"inch", oh)
    # Inclusive 1e-12 in floor. 1.001× absorbs Unitful inflation of
    # (12+1e-12)inch − 12inch → ~1.00009e-12. ENGINEERING JUDGMENT: the
    # relative slack is not a code tolerance; 0.01 in leftover is ~1e10×
    # larger and stays leftover.
    return abs(x) <= _SI_INCH_ULP * 1.001 ? zero(oh) : oh
end

# =============================================================================
# Foundation Demand
# =============================================================================

"""
    FoundationDemand{F, M, L}

Reaction forces from structural analysis at a support node, with per-column
dimensions for punching shear, bearing, and development checks.

# Fields
- `Pu`: Factored axial load (compression positive, tension negative). Isolated
  all-uplift footings may skip design; grouped footings keep the signed couple.
- `Mux`: Factored moment about x-axis
- `Muy`: Factored moment about y-axis
- `Vux`: Factored shear in x
- `Vuy`: Factored shear in y
- `Ps`: Service axial load (signed D+L, not Pu/1.4; tension negative)
- `c1`: Column dimension parallel to footing length (or diameter for circular)
- `c2`: Column dimension perpendicular (= c1 for square/circular)
- `shape`: `:rectangular` or `:circular`
- `uplift`: `true` when the factored vertical reaction is tension (support
  pulling down). A compression footing must not be designed for this demand
  (ACI 318-11 §15.8.1.2, corpus: aci-318-11, page 275).
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
    uplift::Bool    # factored vertical reaction is tension
end

"""
    FoundationDemand(idx; Pu, Mux, Muy, Vux, Vuy, Ps, c1, c2, shape, uplift) → FoundationDemand

Keyword constructor with SI defaults. Column dimensions default to
18 in × 18 in rectangular. `uplift` defaults to `false`.
"""
function FoundationDemand(idx::Int;
                          Pu=0.0u"kN", Mux=0.0u"kN*m", Muy=0.0u"kN*m",
                          Vux=0.0u"kN", Vuy=0.0u"kN", Ps=0.0u"kN",
                          c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular,
                          uplift::Bool=false)
    FoundationDemand{typeof(Pu), typeof(Mux), typeof(c1)}(
        idx, Pu, Mux, Muy, Vux, Vuy, Ps, c1, c2, shape, uplift)
end

# =============================================================================
# Symbol ↔ Type Mapping
# =============================================================================

"""Symbol → foundation singleton lookup table (e.g. `:spread` → `SpreadFooting()`)."""
const foundation_type_map = Dict{Symbol, AbstractFoundation}(
    :spread => SpreadFooting(),
    :combined => CombinedFooting(),
    :strip => StripFooting(),
    :mat => MatFoundation(),
    :driven_pile => DrivenPile(),
    :drilled_shaft => DrilledShaft(),
    :micropile => Micropile(),
)

"""Concrete type → Symbol reverse lookup (e.g. `SpreadFooting` → `:spread`)."""
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
