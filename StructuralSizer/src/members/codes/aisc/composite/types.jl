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
- `e_mid_ht`: distance from the stud shank edge to the deck web, at mid-height
  of the rib, in the load-bearing direction of the stud (AISC 360-22 §I8.2a,
  corpus: aisc-360-22, PDF p. 182). `nothing` means unknown and keeps
  `Rp = 0.6` for perpendicular deck.
- `anchorage_spacing`: spacing of the deck attachments to the supporting
  member (§I3.2c(d), PDF p. 170). `nothing` means not supplied; the limit is
  then reported as unchecked, not as passing.
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
    e_mid_ht::Union{typeof(1.0u"m"), Nothing}
    anchorage_spacing::Union{typeof(1.0u"m"), Nothing}
end

_opt_m(x) = x === nothing ? nothing : uconvert(u"m", x)

function DeckSlabOnBeam(t_slab, fc′, Ec, wc, Es,
                        hr, wr, deck_orientation,
                        beam_spacing_left, beam_spacing_right;
                        edge_dist_left=nothing, edge_dist_right=nothing,
                        e_mid_ht=nothing, anchorage_spacing=nothing)
    deck_orientation in (:perpendicular, :parallel) ||
        throw(ArgumentError("deck_orientation must be :perpendicular or :parallel, got :$deck_orientation"))
    n = ustrip(u"Pa", Es) / ustrip(u"Pa", Ec)
    DeckSlabOnBeam(uconvert(u"m", t_slab), fc′, Ec, wc, n,
                   uconvert(u"m", hr), uconvert(u"m", wr), deck_orientation,
                   uconvert(u"m", beam_spacing_left),
                   uconvert(u"m", beam_spacing_right),
                   _opt_m(edge_dist_left), _opt_m(edge_dist_right),
                   _opt_m(e_mid_ht), _opt_m(anchorage_spacing))
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
- `source`: Where the stud properties came from. Empty for a caller-named
  stud; [`default_headed_stud`](@ref) fills it so results can report it.

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
    ecc::CarbonPerMassQuantity  # Embodied carbon [kgCO₂e/kg], typed via Asap `𝐗` dimension
    n_per_row::Int
    source::String
end

function HeadedStudAnchor(d_sa, l_sa, Fu, Fy, ρ; ecc=1.72u"kgCO2e/kg", n_per_row=1,
                          source::AbstractString="")
    n_per_row >= 1 || throw(ArgumentError("n_per_row must be ≥ 1"))
    HeadedStudAnchor(uconvert(u"m", d_sa), uconvert(u"m", l_sa),
                     Fu, Fy, ρ, _normalize_ecc(ecc), n_per_row, String(source))
end

const DEFAULT_STUD_SOURCE =
    "Default stud: 3/4 in ASTM A108 Type B, Fu = 65 ksi " *
    "(AISC Steel Construction Manual 14th ed., PDF p. 165; corpus: aisc-scm-14th). " *
    "That Manual edition predates AISC 360-22."

"""
    default_headed_stud(; hr=nothing, ρ=490 lb/ft³) -> HeadedStudAnchor

Stud used when composite design is requested and no stud is named.

- `d_sa = 3/4 in`, the largest diameter AISC 360-22 §I8.1 allows through deck
  (corpus: aisc-360-22, PDF p. 181).
- `Fu = 65 ksi` for ASTM A108 Type B studs, AISC Manual 14th ed., PDF p. 165
  (corpus: aisc-scm-14th). Eq. I8-1 uses `Fu`; `Fy` is stored as zero.
- `l_sa = max(4 d_sa, hr + 1.5 in)`: §I8.2 minimum length (PDF p. 181) and,
  on deck, §I3.2c(b) projection above the deck (PDF p. 170). Whether that
  length also leaves 1/2 in of cover is checked against the slab later.

The flange limit `d_sa ≤ 2.5 tf` (§I8.1) rejects sections with `tf < 0.30 in`.
"""
function default_headed_stud(; hr=nothing, ρ=490.0u"lb/ft^3")
    d = 0.75u"inch"
    l = hr === nothing ? 4d : max(4d, uconvert(u"inch", hr) + 1.5u"inch")
    HeadedStudAnchor(d, l, 65.0u"ksi", 0.0u"ksi", ρ; source=DEFAULT_STUD_SOURCE)
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
# Pre-cure loads (filled by construction.jl)
# ==============================================================================

"""
Vertical construction loads for one beam, before the candidate's own weight.

`p_Cp` is SEI/ASCE 37-02 Table 2 for `cp_class`. `p_concrete` is C_VML.
`b_trib` turns those pressures into line loads. `p_L` is the nominal live load
present during construction (the `0.5L` term). `w_D_extra` is D other than the
steel beam. `w_Cd` and `w_Cfml` are line loads.
"""
struct ConstructionStage
    cp_class::Symbol
    p_Cp::typeof(1.0u"Pa")
    p_concrete::typeof(1.0u"Pa")
    b_trib::typeof(1.0u"m")
    p_L::typeof(1.0u"Pa")
    w_D_extra::typeof(1.0u"N/m")
    w_Cd::typeof(1.0u"N/m")
    w_Cfml::typeof(1.0u"N/m")
    # Extrema of the analysis dead-load field, and the uniform line load that
    # produced them. All `nothing` keeps the simple-span statics.
    M_ref::Union{Nothing, typeof(1.0u"N*m")}
    V_ref::Union{Nothing, typeof(1.0u"N")}
    w_ref::Union{Nothing, typeof(1.0u"N/m")}
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
- `Lb_const`:   Unbraced length of the sagging face during construction. Deck defaults to 0 (top flange braced); a solid slab on unattached forms defaults to the span. An explicit length overrides either.
- `Asr`:        Longitudinal reinforcement within `b_eff` at the section of maximum negative moment. A positive area asserts those bars are developed (§I3.2b(c)). Strip totals do not carry bar lengths, so development length is not computed. Place the area with `asr_at_section`. The hogging check uses this one section.
- `Fysr`:       Yield strength of that reinforcement
- `neg_moment`: `true` when steel anchors connect the slab to the beam in the negative-moment region
- `ΣQn_neg`:    Nominal strength of those anchors between the maximum negative moment and the adjacent zero (§I3.2d.2). `nothing` leaves the rebar uncounted.
- `slip_checked`: `true` when the caller has already run the commentary slip model
- `construction`: Pre-cure loads (SEI/ASCE 37-02). Built from the slab when omitted.
- `L_twist`:    Spacing of points that restrain twist, for the hogging Chapter F check and Commentary Eq. C-F1-5. `nothing` uses the member span.

# Notes
- The `AISCChecker` uses this to decide between bare-steel and composite capacity paths.
- `Asr`, `Fysr`, and `ΣQn_neg` are only used when `neg_moment = true`. A missing `ΣQn_neg` keeps hogging on Chapter F.
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
    slip_checked::Bool
    construction::ConstructionStage
    ΣQn_neg::Union{Nothing, Unitful.Quantity}
    L_twist::Union{Nothing, typeof(1.0u"m")}
end

"""
Unbraced length for the pre-cure Chapter F check on the sagging face.

Deck fastened to the top flange is taken as continuous bracing of that flange,
so lateral-torsional buckling does not reduce φMn (`Lb = 0`). A solid slab on
forms that are not attached keeps the member span.

AISC 360-22 Commentary §I3.1b (corpus: aisc-360-22, PDF p. 501): when forms are
not attached to the top flange, bracing during construction may not be
continuous and the unbraced length may control. The deck default is the reverse
of that sentence. It is not a check that the deck can supply the Appendix 6
brace, and it does not brace a hogging region, where the bottom flange is in
compression.
"""
default_construction_Lb(::DeckSlabOnBeam, L_beam) = 0.0u"m"
default_construction_Lb(::SolidSlabOnBeam, L_beam) = uconvert(u"m", L_beam)

function CompositeContext(slab, anchor, L_beam;
                          shored=false, Lb_const=nothing,
                          Asr=0.0u"mm^2", Fysr=0.0u"MPa",
                          neg_moment=false,
                          ΣQn_neg=nothing,
                          slip_checked::Bool=false,
                          cp_class::Union{Symbol, Nothing}=:medium,
                          construction=nothing,
                          L_twist=nothing)
    stage = construction === nothing ?
        construction_stage(slab; cp_class = cp_class) : construction
    lb = Lb_const === nothing ? default_construction_Lb(slab, L_beam) : Lb_const
    if L_twist !== nothing && !(ustrip(u"m", uconvert(u"m", L_twist)) > 0)
        throw(ArgumentError("L_twist must be a positive length, got $L_twist."))
    end
    CompositeContext(slab, anchor, uconvert(u"m", L_beam), shored,
                     uconvert(u"m", lb), Asr, Fysr, neg_moment,
                     slip_checked, stage, ΣQn_neg, _opt_m(L_twist))
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
