# =============================================================================
# Shear Stud Design (for Punching Shear Reinforcement)
# =============================================================================

"""
    ShearStudDesign

Per-column shear stud design per ACI 318-11 §11.11.5 / Ancon Shearfix.

# Fields
- `required`: Whether studs are needed for this column
- `stud_diameter`: Stud diameter (typically 3/8" or 1/2")
- `fyt`: Stud yield strength (from material)
- `n_rails`: Number of stud rails (min 8 for interior, 4-6 for edge/corner)
- `n_studs_per_rail`: Studs per rail (determines shear-reinforced zone extent)
- `s0`: First stud spacing from column face (0.35d to 0.5d)
- `s`: Subsequent spacing (≤ 0.75d, or ≤ 0.5d if high stress)
- `Av_per_line`: Total stud area per peripheral line
- `vs`: Steel contribution to shear stress
- `vcs`: Concrete contribution with studs (reduced)
- `vc_max`: Compression strut limit
- `outer_ok`: Whether outer critical section passes

# Reference
- ACI 318-11 §11.11.5
- Ancon Shearfix Design Manual (adapted to ACI 318-11)
"""
Base.@kwdef struct ShearStudDesign{L<:Asap.Length, A<:Asap.Area, P<:Asap.Pressure}
    required::Bool = false
    catalog_name::Symbol = :generic  # :generic, :incon_iss, :ancon_shearfix
    stud_diameter::L = 0.5u"inch"
    fyt::P = 51000.0u"psi"
    n_rails::Int = 0
    n_studs_per_rail::Int = 0
    s0::L = 0.0u"inch"              # First spacing (from column face)
    s::L = 0.0u"inch"               # Subsequent spacing
    Av_per_line::A = 0.0u"inch^2"   # Total stud area per peripheral line
    vs::P = 0.0u"psi"               # Steel contribution
    vcs::P = 0.0u"psi"              # Reduced concrete contribution
    vc_max::P = 0.0u"psi"           # Compression strut limit
    outer_ok::Bool = true           # Outer critical section passes
end

"""Check if stud design is adequate."""
is_adequate(s::ShearStudDesign) = !s.required || (s.n_rails > 0 && s.outer_ok)

# =============================================================================
# Closed Stirrup Design (for Punching Shear Reinforcement)
# =============================================================================

"""
    ClosedStirrupDesign

Per-column closed stirrup design for punching shear per ACI 318-11 §11.11.3.

# Key differences from headed studs (§11.11.5):
- Vc capped at 2λ√f'c (vs 3λ√f'c for studs)
- Vn capped at 6√f'c·b0·d (vs 8√f'c for studs)
- Minimum d ≥ 6 in. and d ≥ 16·d_b
- Anchorage per §12.13 (difficult in slabs < 10 in.)

# Fields
- `required`: Whether stirrups are needed
- `bar_size`: Stirrup bar designation (#3, #4, etc.)
- `fyt`: Stirrup yield strength
- `n_legs`: Number of stirrup legs per peripheral line
- `n_lines`: Number of peripheral lines (determines reinforced zone extent)
- `s0`: First stirrup spacing from column face (≤ d/2)
- `s`: Subsequent radial spacing (≤ d/2)
- `Av_per_line`: Total stirrup area per peripheral line (n_legs × Ab)
- `vs`: Steel contribution to shear stress (psi)
- `vcs`: Concrete contribution with stirrups (capped at 2λ√f'c, psi)
- `vc_max`: Maximum nominal shear stress (6√f'c, psi)
- `outer_ok`: Whether outer critical section (d/2 beyond last line) passes

# Reference
- ACI 318-11 §11.11.3
"""
Base.@kwdef struct ClosedStirrupDesign{L<:Asap.Length, A<:Asap.Area, P<:Asap.Pressure}
    required::Bool = false
    bar_size::Int = 3                   # Stirrup bar designation (#3, #4, etc.)
    fyt::P = 60000.0u"psi"
    n_legs::Int = 0                     # Legs per peripheral line
    n_lines::Int = 0                    # Number of peripheral lines
    s0::L = 0.0u"inch"                 # First spacing from column face
    s::L = 0.0u"inch"                  # Radial spacing
    Av_per_line::A = 0.0u"inch^2"      # Total stirrup area per line
    vs::P = 0.0u"psi"                  # Steel contribution
    vcs::P = 0.0u"psi"                 # Reduced concrete contribution
    vc_max::P = 0.0u"psi"              # 6√f'c limit
    outer_ok::Bool = true
end

"""Check if stirrup design is adequate."""
is_adequate(s::ClosedStirrupDesign) = !s.required || (s.n_legs > 0 && s.outer_ok)

# =============================================================================
# Shear Cap Design (for Punching Shear Reinforcement)
# =============================================================================

"""
    ShearCapDesign

Per-column shear cap design for punching shear per ACI 318-11 §13.2.6.

A shear cap is a localized thickening below the slab at the column. Two
critical sections are checked (§11.11.1.2): d/2 from the column face through
the cap depth, and d/2 outside the cap edge in the slab.

# Geometry Rule (§13.2.6)
The cap must extend horizontally from the column face at least the
projection depth: `extent ≥ h_cap`. It stops at a slab edge.

# Fields
- `required`: Whether a shear cap is needed
- `h_cap`: Projection depth below the slab soffit
- `extent`: Horizontal extent from column face (≥ h_cap)
- `d_eff`: Effective depth through the cap (d_slab + h_cap), section (a)
- `b0_cap`: Critical perimeter d/2 outside the cap edge, section (b)
- `c1_cap`, `c2_cap`: Cap plan footprint in the column's named axes
- `ratio`: Worse vu / φvc of the two sections
- `ok`: Whether the cap resolves punching
- `governing`: `:column_face`, `:cap_edge`, `:unsupported`, or `:none`

# Reference
- ACI 318-11 §13.2.6, §11.11.1.2
"""
Base.@kwdef struct ShearCapDesign{L<:Asap.Length}
    required::Bool = false
    h_cap::L = 0.0u"inch"              # Projection below slab
    extent::L = 0.0u"inch"             # Horizontal extent from column face
    d_eff::L = 0.0u"inch"              # Effective depth through the cap
    b0_cap::L = 0.0u"inch"             # Critical perimeter outside the cap edge
    c1_cap::L = 0.0u"inch"             # Footprint along c1
    c2_cap::L = 0.0u"inch"             # Footprint along c2
    ratio::Float64 = 0.0               # vu / φvc (worse section)
    ok::Bool = true
    governing::Symbol = :none
    shape::Symbol = :rectangular       # :circular footprint around a round interior column
end

"""Check if shear cap design is adequate."""
is_adequate(s::ShearCapDesign) = !s.required || s.ok

# =============================================================================
# Column Capital Design (for Punching Shear Reinforcement)
# =============================================================================

"""
    ColumnCapitalDesign

Per-column capital design for punching shear per ACI 318-11 §13.1.2.

A column capital is a flared enlargement of the column head. The effective
support area is defined by the 45° cone/pyramid rule: the capital flares
`h_cap` beyond each column face that has slab beyond it.

# 45° Rule (§13.1.2)
Effective support = intersection of slab soffit with the largest right
circular cone / right pyramid whose surfaces are within the column and
capital, oriented ≤ 45° to the column axis.

# Fields
- `required`: Whether a capital is needed
- `h_cap`: Capital projection below the slab soffit
- `c1_eff`, `c2_eff`: Effective support at the slab soffit, named axes
  (`c + 2·h_cap` at an interior column; `c + h_cap` across a free edge)
- `b0_eff`: Critical perimeter using effective dimensions
- `ratio`: vu / φvc at the effective critical section
- `ok`: Whether the capital resolves punching
- `shape`: `:circular` (cone) or `:rectangular` (pyramid) footprint

# Reference
- ACI 318-11 §13.1.2
"""
Base.@kwdef struct ColumnCapitalDesign{L<:Asap.Length}
    required::Bool = false
    h_cap::L = 0.0u"inch"              # Capital projection below slab
    c1_eff::L = 0.0u"inch"             # Effective support along c1
    c2_eff::L = 0.0u"inch"             # Effective support along c2
    b0_eff::L = 0.0u"inch"             # Critical perimeter with capital
    ratio::Float64 = 0.0               # vu / φvc
    ok::Bool = true
    shape::Symbol = :rectangular
end

"""Check if column capital design is adequate."""
is_adequate(s::ColumnCapitalDesign) = !s.required || s.ok

# =============================================================================
# Material Takeoff Helpers for Punching Reinforcement
# =============================================================================

"""
    stud_steel_volume(studs::ShearStudDesign) -> Volume

Total steel volume of all shear studs at one column location.
Each stud is a cylinder: π/4 × d² × h_stud, where h_stud = 5 × d (typical headed stud).
Total = n_rails × n_studs_per_rail × single_stud_volume.
"""
function stud_steel_volume(studs::ShearStudDesign)
    !studs.required && return 0.0u"inch^3"
    d = studs.stud_diameter
    h_stud = 5 * d  # typical headed stud height ≈ 5× shank diameter
    single_vol = π / 4 * d^2 * h_stud
    return studs.n_rails * studs.n_studs_per_rail * single_vol
end

"""
    shear_cap_concrete_volume(cap::ShearCapDesign, c1, c2) -> Volume

Additional concrete volume from a shear cap (thickened head) at one column:
the footprint less the column, times the projection `h_cap` below the slab.
A cap without a recorded footprint extends `extent` from every column face.
For a circular footprint `c1` is the column diameter.
"""
function shear_cap_concrete_volume(cap::ShearCapDesign, c1, c2)
    !cap.required && return 0.0u"inch^3"
    if cap.shape === :circular
        return π / 4 * (cap.c1_cap^2 - c1^2) * cap.h_cap
    end
    has_fp = cap.c1_cap > zero(cap.c1_cap) && cap.c2_cap > zero(cap.c2_cap)
    L1 = has_fp ? cap.c1_cap : c1 + 2 * cap.extent
    L2 = has_fp ? cap.c2_cap : c2 + 2 * cap.extent
    return (L1 * L2 - c1 * c2) * cap.h_cap
end

"""
    capital_concrete_volume(cap::ColumnCapitalDesign, c1, c2) -> Volume
    capital_concrete_volume(cap::ColumnCapitalDesign) -> Volume

Additional concrete volume from a column capital at one column. With the
column size, the 45° flare is a frustum from the column (`c1 × c2`, or
diameter `c1`) at the bottom to the effective support at the slab soffit,
less the column inside it (prismoidal formula, exact for both). Without it,
the bounding prism `c1_eff × c2_eff × h_cap`.
"""
function capital_concrete_volume(cap::ColumnCapitalDesign, c1, c2)
    !cap.required && return 0.0u"inch^3"
    h = cap.h_cap
    if cap.shape === :circular
        D0, D1 = c1, cap.c1_eff
        cone = π * h / 12 * (D0^2 + D0 * D1 + D1^2)
        return cone - π * D0^2 / 4 * h
    end
    a0, b0 = c1, c2
    a1, b1 = cap.c1_eff, cap.c2_eff
    frustum = h / 6 * (a0 * b0 + (a0 + a1) * (b0 + b1) + a1 * b1)
    return frustum - a0 * b0 * h
end

function capital_concrete_volume(cap::ColumnCapitalDesign)
    !cap.required && return 0.0u"inch^3"
    return cap.c1_eff * cap.c2_eff * cap.h_cap
end

"""
    PunchingCheckResult

Per-column punching shear check result with optional reinforcement design.

# Fields
- `ok`: Whether check passes (with or without reinforcement)
- `ratio`: vu / φvc (or vu / φ(vcs+vs) with reinforcement)
- `vu`: Factored shear stress
- `φvc`: Design capacity (concrete only without reinforcement)
- `b0`: Critical perimeter at column
- `Jc`: Polar moment of inertia
- `Vu`: Factored shear force
- `Mub`: Unbalanced moment
- `studs`: Headed shear stud design (nothing if not used)
- `stirrups`: Closed stirrup design (nothing if not used)
- `shear_cap`: Shear cap design (nothing if not used)
- `capital`: Column capital design (nothing if not used)

# Reference
- ACI 318-11 §11.11
"""
Base.@kwdef struct PunchingCheckResult{L<:Asap.Length, P<:Asap.Pressure, F<:Asap.Force, M<:Asap.Moment}
    ok::Bool
    ratio::Float64
    vu::P
    φvc::P
    b0::L
    Jc::Asap.SecondMomentOfArea
    Vu::F
    Mub::M
    studs::Union{ShearStudDesign, Nothing} = nothing
    stirrups::Union{ClosedStirrupDesign, Nothing} = nothing
    shear_cap::Union{ShearCapDesign, Nothing} = nothing
    capital::Union{ColumnCapitalDesign, Nothing} = nothing
end

"""
Strip reinforcement design result (flat plate/slab design).

When `section_adequate = false`, the section is too thin for the moment demand
(Whitney block solution is imaginary). The iteration loop should increase h.
"""
struct StripReinforcement{L<:Asap.Length, A<:Asap.Area, M<:Asap.Moment}
    location::Symbol          # :ext_neg, :pos, :int_neg
    Mu::M                     # Design moment
    As_reqd::A                # Required steel area
    As_min::A                 # Minimum steel area
    As_provided::A            # Provided steel area
    bar_size::Int             # Bar designation (#4, #5, etc.)
    spacing::L                # Bar spacing
    n_bars::Int               # Number of bars
    section_adequate::Bool    # false if section too thin (As_reqd = Inf)
end

"""
    FlatPlatePanelResult

Panel design result for flat plate per ACI 318 DDM/EFM.

Extends `CIPSlabResult` with strip reinforcement and design checks.
Main result type for flat plate design - includes all fields needed
for visualization, analysis, and documentation.

# Core Fields (same interface as CIPSlabResult)
- `thickness`: Slab thickness (same as `h` for compatibility)
- `volume_per_area`: Concrete volume per plan area [m]
- `self_weight`: Self-weight pressure

# Geometry
- `l1`, `l2`: Panel spans in each direction
- `M0`: Total static moment

# Reinforcement Design
- `column_strip_width`, `column_strip_reinf`: Column strip design
- `middle_strip_width`, `middle_strip_reinf`: Middle strip design

# Design Checks
- `punching_check`: Punching shear verification
- `deflection_check`: Two-way deflection verification

# Example
```julia
result = size_flat_plate!(struc, slab, col_opts)
result.thickness          # Slab thickness
result.deflection_ok      # Quick deflection status
result.column_strip_reinf # Reinforcement details
```
"""
struct FlatPlatePanelResult{L<:Asap.Length, F<:Asap.Pressure, M<:Asap.Moment} <: AbstractFloorResult
    # Core fields (CIPSlabResult interface)
    thickness::L              # Slab thickness
    volume_per_area::L        # Concrete volume per plan area [m]
    self_weight::F            # Self-weight pressure
    
    # Loads
    qu::F                     # Factored uniform load: max(1.2D+1.6L, 1.4D)
    
    # Geometry
    l1::L                     # Span in direction 1
    l2::L                     # Span in direction 2
    
    # Analysis
    M0::M                     # Total static moment (primary direction)
    
    # Primary direction reinforcement
    column_strip_width::L
    column_strip_reinf::Vector{<:StripReinforcement}
    
    # Middle strip design  
    middle_strip_width::L
    middle_strip_reinf::Vector{<:StripReinforcement}
    
    # Secondary (perpendicular) direction reinforcement
    # These are populated when secondary moment analysis is performed.
    secondary_column_strip_width::L
    secondary_column_strip_reinf::Vector{<:StripReinforcement}
    secondary_middle_strip_width::L
    secondary_middle_strip_reinf::Vector{<:StripReinforcement}
    
    # Checks
    punching_check::NamedTuple
    deflection_check::NamedTuple

    # Factored moment the slab delivers into a wall, primary span and the
    # perpendicular span. Zero when that direction has no wall support.
    M_wall::M
    M_wall_secondary::M

    # Unfactored (dead, largest live) moment at each wall face behind
    # `M_wall` and `M_wall_secondary`, N·m, top tension positive. Empty when
    # the analysis did not separate dead and live (DDM, EFM, single solve).
    wall_face_parts::Vector{NTuple{2,Float64}}
    wall_face_parts_secondary::Vector{NTuple{2,Float64}}
end

# Convenience constructor from h-based inputs.
# Accepts mixed length units and normalizes to coherent SI internally.
function FlatPlatePanelResult(
    l1::Asap.Length, l2::Asap.Length, h::Asap.Length, M0::M,
    qu::Asap.Pressure,
    cs_width::Asap.Length, cs_reinf::Vector{<:StripReinforcement},
    ms_width::Asap.Length, ms_reinf::Vector{<:StripReinforcement},
    punching::NamedTuple, deflection::NamedTuple;
    γ_concrete = NWC_4000.ρ * GRAVITY,
    sec_cs_width::Asap.Length = 0.0u"m",
    sec_cs_reinf::Vector{<:StripReinforcement} = StripReinforcement[],
    sec_ms_width::Asap.Length = 0.0u"m",
    sec_ms_reinf::Vector{<:StripReinforcement} = StripReinforcement[],
    M_wall::Asap.Moment = 0.0u"kN*m",
    M_wall_secondary::Asap.Moment = 0.0u"kN*m",
    wall_face_parts::Vector{NTuple{2,Float64}} = NTuple{2,Float64}[],
    wall_face_parts_secondary::Vector{NTuple{2,Float64}} = NTuple{2,Float64}[],
) where {M<:Asap.Moment}
    L = typeof(1.0u"m")
    
    thickness_m  = uconvert(u"m", h)
    l1_m         = uconvert(u"m", l1)
    l2_m         = uconvert(u"m", l2)
    cs_width_m   = uconvert(u"m", cs_width)
    ms_width_m   = uconvert(u"m", ms_width)
    M0_si        = uconvert(u"kN*m", M0)
    qu_si        = uconvert(u"kPa", qu)

    sec_cs_w_m = uconvert(u"m", sec_cs_width)
    sec_ms_w_m = uconvert(u"m", sec_ms_width)

    sw = uconvert(u"kPa", γ_concrete * h)
    vol_per_area = thickness_m
    
    return FlatPlatePanelResult{L, typeof(sw), typeof(M0_si)}(
        thickness_m, vol_per_area, sw, qu_si,
        l1_m, l2_m, M0_si,
        cs_width_m, cs_reinf,
        ms_width_m, ms_reinf,
        sec_cs_w_m, sec_cs_reinf,
        sec_ms_w_m, sec_ms_reinf,
        punching, deflection,
        uconvert(u"kN*m", M_wall),
        uconvert(u"kN*m", M_wall_secondary),
        wall_face_parts,
        wall_face_parts_secondary,
    )
end

"""Total depth of a flat plate panel (equal to slab thickness)."""
total_depth(r::FlatPlatePanelResult) = r.thickness
flange_thickness(r::FlatPlatePanelResult) = r.thickness

"""Quick check: does deflection pass?"""
deflection_ok(r::FlatPlatePanelResult) = r.deflection_check.ok

"""Quick check: does punching shear pass?"""
punching_ok(r::FlatPlatePanelResult) = r.punching_check.ok

"""Maximum punching utilization ratio across all columns."""
max_punching_ratio(r::FlatPlatePanelResult) = r.punching_check.max_ratio

"""Deflection ratio (Δ_total / Δ_limit)."""
deflection_ratio(r::FlatPlatePanelResult) = r.deflection_check.ratio

# Backward compatibility: h accessor
Base.getproperty(r::FlatPlatePanelResult, s::Symbol) = 
    s === :h ? getfield(r, :thickness) : getfield(r, s)

# Include both concrete and steel for EC calculations
materials(::FlatPlatePanelResult) = (:concrete, :steel)

