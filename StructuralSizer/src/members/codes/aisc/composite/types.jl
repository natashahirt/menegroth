# ==============================================================================
# Composite Member Types (AISC 360-16 Chapter I)
# ==============================================================================
# Type hierarchy for slab-on-beam composite action and steel anchors.

# ==============================================================================
# Abstract Types
# ==============================================================================

"""Base type for slab-on-beam configurations (solid slab, formed deck, etc.)."""
abstract type AbstractSlabOnBeam end

"""Base type for steel anchors (headed studs, channels)."""
abstract type AbstractSteelAnchor end

# ==============================================================================
# Concrete Slab Types
# ==============================================================================

"""
    SolidSlabOnBeam <: AbstractSlabOnBeam

Solid reinforced-concrete slab on steel beam (no metal deck).

# Fields
- `t_slab`: Total slab thickness
- `fc′`:    Concrete compressive strength (28-day)
- `Ec`:     Concrete modulus of elasticity
- `wc`:     Concrete unit weight (density)
- `n`:      Modular ratio Es/Ec (precomputed for transformed section)
- `beam_spacing_left`:  Distance to adjacent beam centerline (left)
- `beam_spacing_right`: Distance to adjacent beam centerline (right)
- `edge_dist_left`:     Distance to slab edge (left), `nothing` if interior
- `edge_dist_right`:    Distance to slab edge (right), `nothing` if interior

# Notes
- `Rg = 1.0`, `Rp = 0.75` for headed studs welded directly to steel (AISC I8.2a).
- `Ac` for effective width is computed as `b_eff × t_slab`.
"""
struct SolidSlabOnBeam{T_P<:Pressure, T_D<:Density} <: AbstractSlabOnBeam
    t_slab::typeof(1.0u"m")
    fc′::T_P
    Ec::T_P
    wc::T_D
    n::Float64
    beam_spacing_left::typeof(1.0u"m")
    beam_spacing_right::typeof(1.0u"m")
    edge_dist_left::Union{typeof(1.0u"m"), Nothing}
    edge_dist_right::Union{typeof(1.0u"m"), Nothing}
end

function SolidSlabOnBeam(t_slab, fc′, Ec, wc, Es,
                         beam_spacing_left, beam_spacing_right;
                         edge_dist_left=nothing, edge_dist_right=nothing)
    n = ustrip(u"Pa", Es) / ustrip(u"Pa", Ec)
    edl = edge_dist_left  === nothing ? nothing : uconvert(u"m", edge_dist_left)
    edr = edge_dist_right === nothing ? nothing : uconvert(u"m", edge_dist_right)
    SolidSlabOnBeam(uconvert(u"m", t_slab), fc′, Ec, wc, n,
                    uconvert(u"m", beam_spacing_left),
                    uconvert(u"m", beam_spacing_right),
                    edl, edr)
end

"""
    DeckSlabOnBeam <: AbstractSlabOnBeam

Metal-deck composite slab on steel beam per AISC 360-16 §I3.2c (corpus
aisc-360-16, p. 167).

# `Ac` for crushing capacity (current implementation)

`Ac = b_eff × t_slab` is used for **both** perpendicular and parallel deck.
This is the concrete strictly *above* the top of the steel deck ribs:

- **Perpendicular deck** (§I3.2c(2)): rib concrete must be neglected, so
  excluding it is required and exact.
- **Parallel deck** (§I3.2c(3)): rib concrete *may* be included when
  `wr/hr ≥ 1.5` and the longitudinal rib is uninterrupted across the beam
  flange. Excluding it here is **conservative** (it under-reports the
  available compression block, leading to a smaller plastic neutral-axis
  shift and a smaller `Mn`). Using the rib concrete on parallel deck is a
  future enhancement; until then `t_slab` alone defines the available
  block.

In all cases `t_slab` is the concrete thickness above the deck top, and
the total slab depth above the steel flange is `hr + t_slab` (used for
the composite section's elastic neutral axis and `I_transformed`).

# Fields
- `t_slab`: Concrete thickness **above** deck ribs
- `fc′`:    Concrete compressive strength (28-day)
- `Ec`:     Concrete modulus of elasticity
- `wc`:     Concrete unit weight (density)
- `n`:      Modular ratio Es/Ec
- `hr`:     Nominal rib height
- `wr`:     Average rib width
- `deck_orientation`: `:perpendicular` or `:parallel` to beam
- `beam_spacing_left`, `beam_spacing_right`, `edge_dist_left`, `edge_dist_right`: as `SolidSlabOnBeam`
"""
struct DeckSlabOnBeam{T_P<:Pressure, T_D<:Density} <: AbstractSlabOnBeam
    t_slab::typeof(1.0u"m")
    fc′::T_P
    Ec::T_P
    wc::T_D
    n::Float64
    hr::typeof(1.0u"m")
    wr::typeof(1.0u"m")
    deck_orientation::Symbol
    beam_spacing_left::typeof(1.0u"m")
    beam_spacing_right::typeof(1.0u"m")
    edge_dist_left::Union{typeof(1.0u"m"), Nothing}
    edge_dist_right::Union{typeof(1.0u"m"), Nothing}
end

function DeckSlabOnBeam(t_slab, fc′, Ec, wc, Es,
                        hr, wr, deck_orientation,
                        beam_spacing_left, beam_spacing_right;
                        edge_dist_left=nothing, edge_dist_right=nothing)
    deck_orientation in (:perpendicular, :parallel) ||
        throw(ArgumentError("deck_orientation must be :perpendicular or :parallel, got :$deck_orientation"))
    n = ustrip(u"Pa", Es) / ustrip(u"Pa", Ec)
    edl = edge_dist_left  === nothing ? nothing : uconvert(u"m", edge_dist_left)
    edr = edge_dist_right === nothing ? nothing : uconvert(u"m", edge_dist_right)
    DeckSlabOnBeam(uconvert(u"m", t_slab), fc′, Ec, wc, n,
                   uconvert(u"m", hr), uconvert(u"m", wr), deck_orientation,
                   uconvert(u"m", beam_spacing_left),
                   uconvert(u"m", beam_spacing_right),
                   edl, edr)
end

# ==============================================================================
# Steel Anchors
# ==============================================================================

"""
    HeadedStudAnchor <: AbstractSteelAnchor

Steel headed stud anchor per AISC 360-16 Section I8.

# Fields
- `d_sa`:  Stud shank diameter
- `l_sa`:  Stud length (base to top of head, after installation)
- `Fu`:    Specified minimum tensile strength
- `Fy`:    Specified minimum yield strength
- `ρ`:     Steel density (for weight/ECC calculations)
- `ecc`:   Embodied carbon coefficient [kgCO₂e/kg]
- `n_per_row`: Number of studs per transverse row (≥1)

# Notes
- Single-stud mass is computed as `π/4 × d_sa² × l_sa × ρ` (shank only, head negligible).
- `n_per_row > 1` affects spacing checks and `Rg` for deck configurations.
"""
struct HeadedStudAnchor{T_P<:Pressure, T_D<:Density} <: AbstractSteelAnchor
    d_sa::typeof(1.0u"m")
    l_sa::typeof(1.0u"m")
    Fu::T_P
    Fy::T_P
    ρ::T_D
    ecc::Float64
    n_per_row::Int
end

function HeadedStudAnchor(d_sa, l_sa, Fu, Fy, ρ; ecc=1.72, n_per_row=1)
    n_per_row >= 1 || throw(ArgumentError("n_per_row must be ≥ 1"))
    HeadedStudAnchor(uconvert(u"m", d_sa), uconvert(u"m", l_sa),
                     Fu, Fy, ρ, Float64(ecc), n_per_row)
end

"""
    stud_mass(anchor::HeadedStudAnchor) -> mass (kg)

Mass of a single stud shank (cylindrical approximation, head neglected).
"""
function stud_mass(a::HeadedStudAnchor)
    A_sa = π / 4 * a.d_sa^2
    return uconvert(u"kg", A_sa * a.l_sa * a.ρ)
end

# ==============================================================================
# Composite Context (passed alongside ISymmSection in the checker)
# ==============================================================================

"""
    CompositeContext

All composite-specific data needed by the `AISCChecker` for a composite beam.
This struct is built once per beam group and passed to the composite `is_feasible` path.

# Fields
- `slab`:       Slab-on-beam configuration
- `anchor`:     Steel anchor type
- `L_beam`:     Beam span (center-to-center of supports)
- `shored`:     `true` if temporary shoring used during construction
- `Lb_const`:   Unbraced length during construction (before composite, for Chapter F check)
- `Asr`:        Area of developed longitudinal reinforcement within `b_eff` for negative moment
- `Fysr`:       Yield strength of slab reinforcement
- `neg_moment`: `true` if negative moment composite check is requested

# Notes
- The `AISCChecker` uses this to decide between bare-steel and composite capacity paths.
- `Asr` and `Fysr` are only needed when `neg_moment = true`.
- When `shored = false`, construction-stage deflection uses steel Ix alone.
"""
struct CompositeContext{S<:AbstractSlabOnBeam, A<:AbstractSteelAnchor,
                        T_A<:Area, T_P<:Pressure}
    slab::S
    anchor::A
    L_beam::typeof(1.0u"m")
    shored::Bool
    Lb_const::typeof(1.0u"m")
    Asr::T_A
    Fysr::T_P
    neg_moment::Bool
end

function CompositeContext(slab, anchor, L_beam;
                          shored=false, Lb_const=L_beam,
                          Asr=0.0u"mm^2", Fysr=0.0u"MPa",
                          neg_moment=false)
    CompositeContext(slab, anchor, uconvert(u"m", L_beam), shored,
                     uconvert(u"m", Lb_const), Asr, Fysr, neg_moment)
end

# ==============================================================================
# Slab geometry helpers
# ==============================================================================

"""
    _gap_above_steel(slab) -> Length

Gap between the top of the steel beam flange and the bottom of the concrete
slab. Zero for solid slabs, `hr` (rib height) for deck slabs.
"""
_gap_above_steel(::SolidSlabOnBeam) = 0.0u"m"
_gap_above_steel(slab::DeckSlabOnBeam) = slab.hr

"""
    _total_slab_depth(slab) -> Length

Total distance from top of steel section to top of concrete slab.
For solid slabs this equals `t_slab`. For deck slabs this equals `hr + t_slab`.
"""
_total_slab_depth(slab::SolidSlabOnBeam) = slab.t_slab
_total_slab_depth(slab::DeckSlabOnBeam) = slab.hr + slab.t_slab
